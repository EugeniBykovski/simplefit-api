defmodule SimpleFit.Gyms.MemberSecrets do
  @moduledoc """
  Member invitation tokens, recipient digests, sealed addresses and join
  codes (D-G08, threat model T10; SF-95). Internal to `SimpleFit.Gyms`.

  The construction of staff invitations (`SimpleFit.Gyms.InvitationSecrets`)
  with its own salts and prefix, so nothing here ever matches a staff or
  coach secret:

    * **Token:** `sgm_` and 32 random bytes, base64url without padding. Only
      its SHA-256 is stored. Shown once, in the E07 link's URL fragment.
    * **Recipient digest / sealed recipient:** as staff invitations.
    * **Join code:** 8 symbols of the Crockford base32 alphabet (40 bits),
      shown as `ABCD-EFGH`. Stored as `HMAC-SHA256(join_code_key, code)`
      (the lookup key) and an encrypted copy for the gym's staff. Entry is
      forgiving: case, spaces and hyphens are ignored and `O`, `I`, `L` read
      as `0`, `1`, `1`.
    * **Rate-limit keys:** `HMAC-SHA256(rate_limit_key, kind <> 0 <> value)`.

  Nothing here is ever logged.
  """

  alias SimpleFit.Gyms.InvitationSecrets

  @token_prefix "sgm_"
  @token_bytes 32
  @recipient_salt "simplefit gym member recipient v1"
  @sealed_salt "simplefit gym member recipient sealed v1"
  @join_code_salt "simplefit gym join code v1"
  @join_code_sealed_salt "simplefit gym join code sealed v1"
  @rate_limit_salt "simplefit gym member rate limit v1"

  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @code_length 8

  @doc "A new one-time member invitation token."
  @spec generate_token() :: String.t()
  def generate_token,
    do:
      @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  @doc "The stored hash of a submitted token, or `:error` for anything not shaped like one."
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
    do: :crypto.mac(:hmac, :sha256, InvitationSecrets.derive_key(@recipient_salt), address)

  @doc "Encrypts a canonical recipient address for storage."
  @spec seal(String.t()) :: String.t()
  def seal(address) when is_binary(address), do: encrypt(@sealed_salt, address)

  @doc "Decrypts a sealed recipient address."
  @spec open(String.t()) :: {:ok, String.t()} | :error
  def open(sealed) when is_binary(sealed), do: decrypt(@sealed_salt, sealed)

  @doc "A new join code (canonical form, 8 symbols)."
  @spec generate_join_code() :: String.t()
  def generate_join_code do
    for <<byte <- :crypto.strong_rand_bytes(@code_length)>>, into: "" do
      # 256 is a multiple of 32: every symbol is equally likely.
      <<Enum.at(@alphabet, rem(byte, 32))>>
    end
  end

  @doc """
  The canonical form of a typed join code, or `:error` for anything that
  cannot be one (never looked up).
  """
  @spec normalize_join_code(term()) :: {:ok, String.t()} | :error
  def normalize_join_code(code) when is_binary(code) and byte_size(code) <= 32 do
    canonical =
      code
      |> String.upcase()
      |> String.replace(~r/[\s-]/u, "")
      |> String.replace("O", "0")
      |> String.replace(["I", "L"], "1")

    if byte_size(canonical) == @code_length and
         Enum.all?(String.to_charlist(canonical), &(&1 in @alphabet)),
       do: {:ok, canonical},
       else: :error
  end

  def normalize_join_code(_code), do: :error

  @doc "How a canonical join code is shown: `ABCD-EFGH`."
  @spec display_join_code(String.t()) :: String.t()
  def display_join_code(<<first::binary-size(4), last::binary-size(4)>>), do: first <> "-" <> last

  @doc "The lookup digest of a canonical join code."
  @spec join_code_digest(String.t()) :: binary()
  def join_code_digest(code) when is_binary(code),
    do: :crypto.mac(:hmac, :sha256, InvitationSecrets.derive_key(@join_code_salt), code)

  @doc "Encrypts a canonical join code for storage."
  @spec seal_join_code(String.t()) :: String.t()
  def seal_join_code(code) when is_binary(code), do: encrypt(@join_code_sealed_salt, code)

  @doc "Decrypts a sealed join code."
  @spec open_join_code(String.t()) :: {:ok, String.t()} | :error
  def open_join_code(sealed) when is_binary(sealed), do: decrypt(@join_code_sealed_salt, sealed)

  @doc "A rate-limit key for `kind` and `value` (nothing personal is stored)."
  @spec rate_limit_key(String.t(), String.t()) :: binary()
  def rate_limit_key(kind, value) when is_binary(kind) and is_binary(value),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        InvitationSecrets.derive_key(@rate_limit_salt),
        kind <> <<0>> <> value
      )

  defp encrypt(salt, value),
    do: Plug.Crypto.encrypt(InvitationSecrets.derive_key(salt), salt, value, max_age: :infinity)

  defp decrypt(salt, sealed) do
    case Plug.Crypto.decrypt(InvitationSecrets.derive_key(salt), salt, sealed, max_age: :infinity) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end
end
