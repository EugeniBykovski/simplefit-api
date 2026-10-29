defmodule SimpleFit.Gyms.InvitationSecrets do
  @moduledoc """
  Tokens, recipient digests and sealed recipient addresses of gym staff
  invitations (ADR 0026, D-G12; SF-93). Internal to `SimpleFit.Gyms`.

  The same construction as coach invitations (SF-57), with its own salts, so
  a gym digest or token never matches a coaching one:

    * **Token:** `sfs_` and 32 random bytes, base64url without padding. Only
      its SHA-256 is stored. Shown once, in the E06 link's URL fragment.
    * **Recipient digest:** `HMAC-SHA256(recipient_key, canonical email)`,
      compared with the digests of the accepting user's verified email
      identities, never with a plain address.
    * **Sealed recipient:** `Plug.Crypto.encrypt/4` of the canonical
      address, for resends and the masked address shown to the gym.
    * **Rate-limit keys:** `HMAC-SHA256(rate_limit_key, kind <> 0 <> value)`.

  Keys derive from the `SimpleFit.Gyms` `secret_key_base` (`SECRET_KEY_BASE`)
  with `Plug.Crypto.KeyGenerator`. Nothing here is ever logged.
  """

  alias Plug.Crypto.KeyGenerator

  @token_prefix "sfs_"
  @token_bytes 32
  @recipient_salt "simplefit gym staff recipient v1"
  @sealed_salt "simplefit gym staff recipient sealed v1"
  @rate_limit_salt "simplefit gym staff rate limit v1"

  @doc "A new one-time invitation token."
  @spec generate_token() :: String.t()
  def generate_token,
    do:
      @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  @doc """
  The stored hash of a submitted token, or `:error` for anything not shaped
  like a staff invitation token (never looked up).
  """
  @spec token_hash(term()) :: {:ok, binary()} | :error
  def token_hash(@token_prefix <> encoded = token) when byte_size(encoded) == 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, <<_::binary-size(@token_bytes)>>} -> {:ok, :crypto.hash(:sha256, token)}
      _ -> :error
    end
  end

  def token_hash(_token), do: :error

  @doc "The hash of a token this module generated."
  @spec hash!(String.t()) :: binary()
  def hash!(token) do
    {:ok, hash} = token_hash(token)
    hash
  end

  @doc "The recipient digest of a canonical email address."
  @spec recipient_digest(String.t()) :: binary()
  def recipient_digest(address) when is_binary(address),
    do: :crypto.mac(:hmac, :sha256, key(@recipient_salt), address)

  @doc "Encrypts a canonical recipient address for storage."
  @spec seal(String.t()) :: String.t()
  def seal(address) when is_binary(address),
    do: Plug.Crypto.encrypt(key(@sealed_salt), @sealed_salt, address, max_age: :infinity)

  @doc "Decrypts a sealed recipient address."
  @spec open(String.t()) :: {:ok, String.t()} | :error
  def open(sealed) when is_binary(sealed) do
    case Plug.Crypto.decrypt(key(@sealed_salt), @sealed_salt, sealed, max_age: :infinity) do
      {:ok, address} when is_binary(address) -> {:ok, address}
      _ -> :error
    end
  end

  @doc "A rate-limit key for `kind` and `value` (nothing personal is stored)."
  @spec rate_limit_key(String.t(), String.t()) :: binary()
  def rate_limit_key(kind, value) when is_binary(kind) and is_binary(value),
    do: :crypto.mac(:hmac, :sha256, key(@rate_limit_salt), kind <> <<0>> <> value)

  defp key(salt) do
    KeyGenerator.generate(secret_key_base(), salt,
      length: 32,
      digest: :sha256,
      cache: Plug.Crypto.Keys
    )
  end

  defp secret_key_base do
    case Application.get_env(:simple_fit, SimpleFit.Gyms, [])[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 64 ->
        secret

      _missing ->
        raise ArgumentError,
              "SimpleFit.Gyms: secret_key_base must be at least 64 bytes (SECRET_KEY_BASE)"
    end
  end
end
