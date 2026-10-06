defmodule SimpleFit.Accounts.EmailAuth.Secrets do
  @moduledoc """
  Credentials and verifiers of passwordless email authentication (ADR 0012).
  Internal to `SimpleFit.Accounts`.

  Every key is a dedicated 32-byte key derived from the configured
  `secret_key_base` (`SECRET_KEY_BASE` in production) with
  `Plug.Crypto.KeyGenerator` (PBKDF2-HMAC-SHA256) and its own salt, so the
  keys are independent of each other and of the session signing key:

    * `"simplefit email auth code v1"` - code verifiers
    * `"simplefit email auth target v1"` - target digests of email addresses
    * `"simplefit auth rate limit v1"` - rate-limit keys

  Constructions:

    * **6-digit code:** a uniform value in `0..999_999` from
      `:crypto.strong_rand_bytes/1` with rejection sampling (no modulo bias),
      zero-padded.
    * **Code verifier:** `HMAC-SHA256(code_key, "sfec1" <> 0 <> purpose <> 0 <>
      challenge_id (16 bytes) <> 0 <> code)`. A plain hash of a 6-digit code
      could be brute-forced from a database copy; the keyed verifier cannot,
      and binding the purpose and the challenge id means a code never
      verifies another challenge or the other purpose. Compared with
      `Plug.Crypto.secure_compare/2`.
    * **Target digest:** `HMAC-SHA256(target_key, canonical email)`.
    * **Tokens:** a prefix and 32 random bytes, base64url without padding
      (43 characters). Only their SHA-256 is stored: they carry 256 bits of
      entropy, so a fast hash is enough, as for SF-20 refresh tokens.

  Nothing here is ever logged; the derived keys never leave this module.
  """

  alias Plug.Crypto.KeyGenerator

  @code_salt "simplefit email auth code v1"
  @target_salt "simplefit email auth target v1"
  @rate_limit_salt "simplefit auth rate limit v1"

  @code_space 1_000_000
  # The largest multiple of 1_000_000 below 2^32: values at or above it are
  # redrawn so that every code is equally likely.
  @code_bound div(0x1_0000_0000, @code_space) * @code_space

  @token_bytes 32
  @token_prefixes %{link: "sfv_", registration: "sfg_"}

  @typedoc "A challenge purpose."
  @type purpose :: :verification | :sign_in

  @typedoc "A token kind."
  @type token_kind :: :link | :registration

  @doc ~S|A random 6-digit code, "000000".."999999".|
  @spec generate_code() :: String.t()
  def generate_code do
    <<value::unsigned-integer-size(32)>> = :crypto.strong_rand_bytes(4)

    if value < @code_bound do
      value |> rem(@code_space) |> Integer.to_string() |> String.pad_leading(6, "0")
    else
      generate_code()
    end
  end

  @doc "Whether `code` has the shape of a code: exactly six ASCII digits."
  @spec code?(term()) :: boolean()
  def code?(code), do: is_binary(code) and String.match?(code, ~r/\A[0-9]{6}\z/)

  @doc "The keyed verifier of `code` for the challenge `challenge_id` (a UUID string)."
  @spec code_verifier(purpose(), Ecto.UUID.t(), String.t()) :: binary()
  def code_verifier(purpose, challenge_id, code) when purpose in [:verification, :sign_in] do
    {:ok, id} = Ecto.UUID.dump(challenge_id)
    hmac(@code_salt, ["sfec1", 0, Atom.to_string(purpose), 0, id, 0, code])
  end

  @doc "Constant-time check of `code` against a stored verifier."
  @spec code_matches?(purpose(), Ecto.UUID.t(), String.t(), binary()) :: boolean()
  def code_matches?(purpose, challenge_id, code, verifier) do
    Plug.Crypto.secure_compare(code_verifier(purpose, challenge_id, code), verifier)
  end

  @doc """
  A verifier no code can match, for challenges that must look real but can
  never succeed (enumeration-resistant decoys).
  """
  @spec unmatchable_verifier() :: binary()
  def unmatchable_verifier, do: :crypto.strong_rand_bytes(32)

  @doc "The keyed digest identifying a canonical email address."
  @spec target_digest(String.t()) :: binary()
  def target_digest(canonical_email), do: hmac(@target_salt, canonical_email)

  @doc "The keyed digest of a rate-limit key within `bucket`."
  @spec rate_limit_key(String.t(), String.t()) :: binary()
  def rate_limit_key(bucket, value), do: hmac(@rate_limit_salt, [bucket, 0, value])

  @doc "A new token of `kind` and the SHA-256 that is stored for it."
  @spec generate_token(token_kind()) :: {String.t(), binary()}
  def generate_token(kind) do
    token =
      Map.fetch!(@token_prefixes, kind) <>
        Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    {token, token_hash(token)}
  end

  @doc "The stored hash of a token of `kind`, or `:error` when it is malformed."
  @spec parse_token(token_kind(), term()) :: {:ok, binary()} | :error
  def parse_token(kind, token) when is_binary(token) do
    prefix = Map.fetch!(@token_prefixes, kind)

    if String.match?(token, ~r/\A#{prefix}[A-Za-z0-9_-]{43}\z/),
      do: {:ok, token_hash(token)},
      else: :error
  end

  def parse_token(_kind, _token), do: :error

  defp token_hash(token), do: :crypto.hash(:sha256, token)

  defp hmac(salt, data), do: :crypto.mac(:hmac, :sha256, key(salt), data)

  defp key(salt) do
    KeyGenerator.generate(secret_key_base(), salt,
      length: 32,
      digest: :sha256,
      cache: Plug.Crypto.Keys
    )
  end

  defp secret_key_base do
    case Application.get_env(:simple_fit, SimpleFit.Accounts.EmailAuth, [])[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 64 ->
        secret

      _missing ->
        raise ArgumentError,
              "SimpleFit.Accounts.EmailAuth: secret_key_base must be at least 64 bytes (SECRET_KEY_BASE)"
    end
  end
end
