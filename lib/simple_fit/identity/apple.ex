defmodule SimpleFit.Identity.Apple do
  @moduledoc """
  Verification of Sign in with Apple identity tokens (ADR 0014).

  A client (Apple JS on the web, `AuthenticationServices` on iOS) obtains an
  Apple identity token for a request carrying `SHA-256(raw nonce)` and sends
  the token with the raw nonce to the API. This module decides, independently
  of the client, whether the pair proves an Apple account:

    1. **Header:** a protected header with `alg: RS256` and a non-empty `kid`
       (`alg: none`, HMAC and every other algorithm are rejected before any
       key is used).
    2. **Signature:** `JOSE.JWT.verify_strict/3` (RS256 only) with the key
       named by `kid` from Apple's published keys
       (`SimpleFit.Identity.Apple.Keys`).
    3. **`iss`:** exactly `https://appleid.apple.com`.
    4. **`aud`:** a single string in `APPLE_SIGN_IN_CLIENT_IDS` (the iOS
       bundle id for native tokens, the Services ID for web tokens). Apple
       tokens carry no `azp`.
    5. **Time:** `exp` in the future and `iat` (required) not in the future,
       with 30 s of clock leeway.
    6. **`sub`:** printable ASCII, 1..255 characters (the SF-19
       provider-subject rule).
    7. **`nonce`:** equal to the lowercase hex SHA-256 of the raw nonce,
       compared in constant time. A token without the matching raw nonce is
       useless, so a leaked token cannot be replayed by someone else.

  The result is only `%{provider: :apple, subject: sub}`. Email,
  `email_verified`, `is_private_email`, name and `real_user_status` are never
  read (SimpleFit requests no Apple scopes). Failures are bounded reason
  atoms; token contents never appear in errors, logs or telemetry.
  """

  require Logger

  alias SimpleFit.Identity.Apple.Keys

  @issuer "https://appleid.apple.com"
  @leeway 30
  @client_id ~r/\A[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\z/

  @typedoc "An identity token and the raw nonce its request was made with."
  @type credential :: %{id_token: String.t(), nonce: String.t()}

  @typedoc "Why a credential was rejected."
  @type rejection ::
          :malformed
          | :unsupported_algorithm
          | :unknown_key
          | :bad_signature
          | :issuer
          | :audience
          | :expired
          | :not_yet_valid
          | :subject
          | :nonce

  @type result ::
          {:ok, %{provider: :apple, subject: String.t()}}
          | {:error, {:rejected, rejection()}}
          | {:error, :unavailable | :not_configured}

  @doc "Verifies an Apple identity token against the raw nonce of its request."
  @spec verify(term()) :: result()
  def verify(%{id_token: token, nonce: nonce}) when is_binary(token) and is_binary(nonce) do
    case client_ids() do
      [] -> {:error, :not_configured}
      client_ids -> verify(token, nonce, client_ids)
    end
  end

  def verify(_credential), do: {:error, {:rejected, :malformed}}

  @doc """
  Parses `APPLE_SIGN_IN_CLIENT_IDS`: comma-separated Apple client ids (the iOS
  bundle id and the web Services ID), trimmed, without empty entries and
  duplicates. Unset or blank is `[]` (not configured). Raises on a malformed
  id, so a deployment fails at boot.
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
              "APPLE_SIGN_IN_CLIENT_IDS must be comma-separated Apple client ids (bundle id or Services ID)"
    end
  end

  @doc """
  Boot-time check (called by `SimpleFit.Application`): Apple configuration is
  optional, so an empty allow-list never blocks boot, but it is logged once at
  `:warning` because every Apple sign-in will answer `service_unavailable`.
  Only the reason is logged, never client ids.
  """
  @spec warn_if_not_configured() :: :ok
  def warn_if_not_configured do
    if client_ids() == [] do
      Logger.warning("apple sign-in not configured: APPLE_SIGN_IN_CLIENT_IDS is empty",
        reason: :not_configured
      )
    end

    :ok
  end

  @doc "The configured accepted client ids (audiences)."
  @spec client_ids() :: [String.t()]
  def client_ids, do: Application.get_env(:simple_fit, __MODULE__, [])[:client_ids] || []

  defp verify(token, nonce, client_ids) do
    with {:ok, kid} <- header_kid(token),
         {:ok, jwk} <- key(kid),
         {:ok, claims} <- signed_claims(jwk, token),
         :ok <- check_claims(claims, client_ids, nonce, System.os_time(:second)) do
      {:ok, %{provider: :apple, subject: claims["sub"]}}
    end
  end

  defp header_kid(token) do
    case JOSE.JWT.peek_protected(token) do
      %JOSE.JWS{alg: {:jose_jws_alg_rsa_pkcs1_v1_5, :RS256}, fields: %{"kid" => kid}}
      when is_binary(kid) and kid != "" ->
        {:ok, kid}

      %JOSE.JWS{alg: {:jose_jws_alg_rsa_pkcs1_v1_5, :RS256}} ->
        rejected(:malformed)

      %JOSE.JWS{} ->
        rejected(:unsupported_algorithm)
    end
  rescue
    _malformed -> rejected(:malformed)
  end

  defp key(kid) do
    case Keys.fetch(kid) do
      {:ok, jwk} -> {:ok, jwk}
      {:error, :unknown_key} -> rejected(:unknown_key)
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp signed_claims(jwk, token) do
    case JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      {false, _jwt, _jws} -> rejected(:bad_signature)
    end
  rescue
    _malformed -> rejected(:malformed)
  end

  # Checked in order; the first failure is the reason.
  defp check_claims(claims, client_ids, nonce, now) do
    checks = [
      issuer: fn -> claims["iss"] == @issuer end,
      audience: fn -> is_binary(claims["aud"]) and claims["aud"] in client_ids end,
      expired: fn -> is_integer(claims["exp"]) and claims["exp"] > now - @leeway end,
      not_yet_valid: fn -> is_integer(claims["iat"]) and claims["iat"] <= now + @leeway end,
      subject: fn -> subject?(claims["sub"]) end,
      nonce: fn -> nonce?(claims["nonce"], nonce) end
    ]

    case Enum.find(checks, fn {_reason, check} -> not check.() end) do
      nil -> :ok
      {reason, _check} -> rejected(reason)
    end
  end

  # The SF-19 provider_subject rule: printable ASCII, no spaces, 1..255.
  defp subject?(sub), do: is_binary(sub) and Regex.match?(~r/\A[\x21-\x7e]{1,255}\z/, sub)

  defp nonce?(claim, raw) when is_binary(claim) do
    expected = :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(claim, expected)
  end

  defp nonce?(_claim, _raw), do: false

  defp rejected(reason), do: {:error, {:rejected, reason}}
end
