defmodule SimpleFit.Identity.Google do
  @moduledoc """
  Verification of Google ID tokens (ADR 0013).

  A client (web Google Identity Services, iOS or Android Google Sign-In)
  obtains a Google ID token and sends it to the API; this module decides,
  independently of the client, whether it proves a Google account:

    * **Signature:** RS256 only (`JOSE.JWT.verify_strict/3`), with the key
      named by the header's `kid` from Google's published keys
      (`SimpleFit.Identity.Google.Keys`). `alg: none`, HMAC and every other
      algorithm are rejected before any key is used.
    * **`iss`:** exactly `accounts.google.com` or `https://accounts.google.com`.
    * **`aud`:** a single string in `GOOGLE_OAUTH_CLIENT_IDS`.
    * **`azp`:** when present, also in `GOOGLE_OAUTH_CLIENT_IDS`. Android
      tokens carry `aud` = the web client and `azp` = the Android client.
    * **Time:** `exp` in the future, `iat` (required) and `nbf` (when
      present) not in the future, with 30 s of clock leeway.
    * **`sub`:** required; printable ASCII, 1..255 characters (the SF-19
      provider-subject rule).

  The result is only `%{provider: :google, subject: sub}`: email, name and
  picture claims are never read. Failures are bounded reason atoms; token
  contents never appear in errors, logs or telemetry.
  """

  require Logger

  alias SimpleFit.Identity.Google.Keys

  @issuers ["accounts.google.com", "https://accounts.google.com"]
  @leeway 30
  @client_id ~r/\A[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com\z/

  @typedoc "Why a token was rejected."
  @type rejection ::
          :malformed
          | :unsupported_algorithm
          | :unknown_key
          | :bad_signature
          | :issuer
          | :audience
          | :authorized_party
          | :expired
          | :not_yet_valid
          | :subject

  @type result ::
          {:ok, %{provider: :google, subject: String.t()}}
          | {:error, {:rejected, rejection()}}
          | {:error, :unavailable | :not_configured}

  @doc "Verifies a Google ID token."
  @spec verify(term()) :: result()
  def verify(token) when is_binary(token) do
    case client_ids() do
      [] -> {:error, :not_configured}
      client_ids -> verify(token, client_ids)
    end
  end

  def verify(_token), do: {:error, {:rejected, :malformed}}

  @doc """
  Parses `GOOGLE_OAUTH_CLIENT_IDS`: comma-separated OAuth client ids,
  trimmed, without empty entries and duplicates. Unset or blank is `[]` (not
  configured). Raises on a malformed id, so a deployment fails at boot.
  """
  @spec parse_client_ids!(String.t() | nil) :: [String.t()]
  def parse_client_ids!(nil), do: []

  def parse_client_ids!(value) when is_binary(value) do
    ids =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case Enum.reject(ids, &Regex.match?(@client_id, &1)) do
      [] ->
        ids

      _invalid ->
        raise ArgumentError,
              "GOOGLE_OAUTH_CLIENT_IDS must be comma-separated Google OAuth client ids (<number>-<id>.apps.googleusercontent.com)"
    end
  end

  @doc """
  Boot-time check (called by `SimpleFit.Application`): Google configuration is
  optional, so an empty allow-list never blocks boot, but it is logged once at
  `:warning` because every Google sign-in will answer `service_unavailable`.
  Only the reason is logged, never client ids.
  """
  @spec warn_if_not_configured() :: :ok
  def warn_if_not_configured do
    if client_ids() == [] do
      Logger.warning("google sign-in not configured: GOOGLE_OAUTH_CLIENT_IDS is empty",
        reason: :not_configured
      )
    end

    :ok
  end

  @doc "The configured accepted client ids (audiences and authorized parties)."
  @spec client_ids() :: [String.t()]
  def client_ids, do: Application.get_env(:simple_fit, __MODULE__, [])[:client_ids] || []

  defp verify(token, client_ids) do
    with {:ok, kid} <- header_kid(token),
         {:ok, jwk} <- key(kid),
         {:ok, claims} <- signed_claims(jwk, token),
         :ok <- check_claims(claims, client_ids, System.os_time(:second)) do
      {:ok, %{provider: :google, subject: claims["sub"]}}
    end
  end

  defp header_kid(token) do
    case JOSE.JWT.peek_protected(token) do
      %JOSE.JWS{alg: {:jose_jws_alg_rsa_pkcs1_v1_5, :RS256}, fields: %{"kid" => kid}}
      when is_binary(kid) ->
        {:ok, kid}

      %JOSE.JWS{} ->
        {:error, {:rejected, :unsupported_algorithm}}
    end
  rescue
    _malformed -> {:error, {:rejected, :malformed}}
  end

  defp key(kid) do
    case Keys.fetch(kid) do
      {:ok, jwk} -> {:ok, jwk}
      {:error, :unknown_key} -> {:error, {:rejected, :unknown_key}}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp signed_claims(jwk, token) do
    case JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      {false, _jwt, _jws} -> {:error, {:rejected, :bad_signature}}
    end
  rescue
    _malformed -> {:error, {:rejected, :malformed}}
  end

  # Checked in order; the first failure is the reason.
  defp check_claims(claims, client_ids, now) do
    checks = [
      issuer: fn -> claims["iss"] in @issuers end,
      audience: fn -> is_binary(claims["aud"]) and claims["aud"] in client_ids end,
      authorized_party: fn -> not Map.has_key?(claims, "azp") or claims["azp"] in client_ids end,
      expired: fn -> is_integer(claims["exp"]) and claims["exp"] > now - @leeway end,
      not_yet_valid: fn -> is_integer(claims["iat"]) and claims["iat"] <= now + @leeway end,
      not_yet_valid: fn -> nbf_ok?(claims["nbf"], now) end,
      subject: fn -> subject?(claims["sub"]) end
    ]

    case Enum.find(checks, fn {_reason, check} -> not check.() end) do
      nil -> :ok
      {reason, _check} -> rejected(reason)
    end
  end

  defp nbf_ok?(nil, _now), do: true
  defp nbf_ok?(nbf, now) when is_integer(nbf), do: nbf <= now + @leeway
  defp nbf_ok?(_nbf, _now), do: false

  # The SF-19 provider_subject rule: printable ASCII, no spaces, 1..255.
  defp subject?(sub), do: is_binary(sub) and Regex.match?(~r/\A[\x21-\x7e]{1,255}\z/, sub)

  defp rejected(reason), do: {:error, {:rejected, reason}}
end
