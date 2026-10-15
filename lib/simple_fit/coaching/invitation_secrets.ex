defmodule SimpleFit.Coaching.InvitationSecrets do
  @moduledoc """
  Tokens, digests and sealed recipient addresses of coach invitations
  (SF-57; SF-49 §7.2). Internal to `SimpleFit.Coaching`.

  Every key is a dedicated 32-byte key derived from the configured
  `secret_key_base` (`SECRET_KEY_BASE` in production) with
  `Plug.Crypto.KeyGenerator` and its own salt, as in ADR 0012:

    * **Token:** `sfi_` and 32 random bytes, base64url without padding.
      Only its SHA-256 is stored (256 bits of entropy: a fast hash is
      enough, as for refresh tokens). Shown once, in the E08 link.
    * **Recipient digest:** `HMAC-SHA256(recipient_key, canonical email)`;
      compared with the digests of the accepting user's verified email
      identities, never with a plain address.
    * **Sealed recipient:** `Plug.Crypto.encrypt/4` of the canonical
      address, for resends and the masked address shown to the coach.
    * **Rate-limit keys:** `HMAC-SHA256(rate_limit_key, kind <> 0 <> value)`.

  Nothing here is ever logged; derived keys never leave this module.
  """

  alias Plug.Crypto.KeyGenerator

  @token_prefix "sfi_"
  @token_bytes 32
  @recipient_salt "simplefit coaching recipient v1"
  @sealed_salt "simplefit coaching recipient sealed v1"
  @rate_limit_salt "simplefit coaching rate limit v1"

  @doc "A new one-time invitation token."
  @spec generate_token() :: String.t()
  def generate_token,
    do:
      @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  @doc """
  The stored hash of a submitted token, or `:error` for anything that is
  not shaped like an invitation token (never looked up).
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
    case Application.get_env(:simple_fit, SimpleFit.Coaching.Invitations, [])[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 64 ->
        secret

      _missing ->
        raise ArgumentError,
              "SimpleFit.Coaching.Invitations: secret_key_base must be at least 64 bytes (SECRET_KEY_BASE)"
    end
  end
end
