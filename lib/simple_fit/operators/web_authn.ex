defmodule SimpleFit.Operators.WebAuthn do
  @moduledoc """
  WebAuthn ceremonies for operator security keys, verified by `wax_` (SF-110).
  The server issues every challenge, keeps it, and checks the relying party id,
  the origin, user presence and **user verification** (`required`), the
  signature and the signature counter. Attestation is `none`: SimpleFit doesn't
  verify the authenticator's maker (ADR 0028).

  Configuration (`config :simple_fit, SimpleFit.Operators.WebAuthn`): `rp_id`,
  `origin` and `rp_name`. Without `rp_id` and `origin` the ceremonies answer
  `:service_unavailable`.
  """

  alias SimpleFit.Operators.{Credential, Policy}

  @type registered :: %{
          credential_id: binary(),
          cose_key: binary(),
          sign_count: non_neg_integer(),
          aaguid: binary() | nil,
          backup_eligible: boolean()
        }

  @doc "Whether the relying party is configured."
  @spec configured?() :: boolean()
  def configured?, do: is_binary(config()[:rp_id]) and is_binary(config()[:origin])

  @doc "A fresh challenge, as raw bytes and the Unix second it was issued."
  @spec new_challenge_bytes() :: {binary(), integer()}
  def new_challenge_bytes, do: {:crypto.strong_rand_bytes(32), System.system_time(:second)}

  @doc """
  Browser options for registering a key, in the WebAuthn JSON form
  (`PublicKeyCredential.parseCreationOptionsFromJSON`), hence camelCase.
  """
  @spec registration_options(binary(), Ecto.UUID.t(), [Credential.t()]) :: map()
  def registration_options(bytes, operator_id, existing) do
    %{
      challenge: b64(bytes),
      rp: %{id: config()[:rp_id], name: config()[:rp_name] || "SimpleFit Control Plane"},
      user: %{id: b64(operator_id), name: "operator", displayName: "SimpleFit operator"},
      pubKeyCredParams: [%{type: "public-key", alg: -7}, %{type: "public-key", alg: -8}],
      timeout: Policy.challenge_ttl() * 1000,
      attestation: "none",
      authenticatorSelection: %{
        authenticatorAttachment: "cross-platform",
        residentKey: "discouraged",
        userVerification: "required"
      },
      excludeCredentials: Enum.map(existing, &%{type: "public-key", id: b64(&1.credential_id)})
    }
  end

  @doc "Browser options for verifying a key, in the WebAuthn JSON form (camelCase)."
  @spec assertion_options(binary(), [Credential.t()]) :: map()
  def assertion_options(bytes, credentials) do
    %{
      challenge: b64(bytes),
      rpId: config()[:rp_id],
      timeout: Policy.challenge_ttl() * 1000,
      userVerification: "required",
      allowCredentials: Enum.map(credentials, &%{type: "public-key", id: b64(&1.credential_id)})
    }
  end

  @doc "Verifies a registration response against the stored challenge."
  @spec verify_registration(binary(), binary(), binary(), integer()) ::
          {:ok, registered()} | {:error, atom()}
  def verify_registration(attestation_object, client_data_json, bytes, issued_at) do
    challenge = challenge(:new_registration_challenge, bytes, issued_at, [])

    case Wax.register(attestation_object, client_data_json, challenge) do
      {:ok, {auth_data, _attestation}} ->
        data = auth_data.attested_credential_data

        {:ok,
         %{
           credential_id: data.credential_id,
           cose_key: :erlang.term_to_binary(data.credential_public_key),
           sign_count: auth_data.sign_count,
           aaguid: data.aaguid,
           backup_eligible: auth_data.flag_backup_eligible == true
         }}

      {:error, _reason} ->
        {:error, :security_key_rejected}
    end
  end

  @doc """
  Verifies an assertion with `credential` against the stored challenge. Returns
  the new signature counter.
  """
  @spec verify_assertion(Credential.t(), binary(), binary(), binary(), binary(), integer()) ::
          {:ok, non_neg_integer()} | {:error, :security_key_rejected}
  def verify_assertion(
        %Credential{} = credential,
        auth_data,
        signature,
        client_data_json,
        bytes,
        issued_at
      ) do
    with {:ok, cose_key} <- cose_key(credential.cose_key),
         allowed = [{credential.credential_id, cose_key}],
         challenge =
           challenge(:new_authentication_challenge, bytes, issued_at, allow_credentials: allowed),
         {:ok, data} <-
           Wax.authenticate(
             credential.credential_id,
             auth_data,
             signature,
             client_data_json,
             challenge,
             allowed
           ),
         :ok <- counter_advanced(credential.sign_count, data.sign_count) do
      {:ok, data.sign_count}
    else
      _rejected -> {:error, :security_key_rejected}
    end
  end

  # The COSE public key as Wax decoded it at registration: a map of integers and
  # binaries. Read back with `:safe`, and only from SimpleFit's own column.
  defp cose_key(stored) do
    case :erlang.binary_to_term(stored, [:safe]) do
      %{} = key -> {:ok, key}
      _other -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # A counter that doesn't advance on an authenticator that keeps one is a sign of a
  # cloned key. Authenticators that always report 0 keep no counter.
  defp counter_advanced(0, 0), do: :ok
  defp counter_advanced(stored, new) when new > stored, do: :ok
  defp counter_advanced(_stored, _new), do: :error

  defp challenge(fun, bytes, issued_at, opts) do
    base = [
      bytes: bytes,
      origin: config()[:origin],
      rp_id: config()[:rp_id],
      attestation: "none",
      user_verification: "required",
      timeout: Policy.challenge_ttl(),
      trusted_attestation_types: [:none, :self, :basic, :uncertain, :attca, :anonca],
      verify_trust_root: false
    ]

    %{apply(Wax, fun, [Keyword.merge(base, opts)]) | issued_at: issued_at}
  end

  @doc "URL-safe Base64 without padding, as WebAuthn uses."
  @spec b64(binary()) :: String.t()
  def b64(bin), do: Base.url_encode64(bin, padding: false)

  @doc "Decodes URL-safe Base64, with or without padding."
  @spec decode64(term()) :: {:ok, binary()} | :error
  def decode64(value) when is_binary(value) and byte_size(value) <= 16_384,
    do: Base.url_decode64(value, padding: false)

  def decode64(_value), do: :error

  defp config, do: Application.get_env(:simple_fit, __MODULE__, [])
end
