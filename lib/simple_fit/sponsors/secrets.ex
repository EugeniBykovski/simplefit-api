defmodule SimpleFit.Sponsors.Secrets do
  @moduledoc """
  Keyed digests for sponsor applications (SF-114): contact email digests and
  verification code verifiers, `HMAC-SHA256` with keys derived from the sponsors'
  `secret_key_base` (`SECRET_KEY_BASE`) by `Plug.Crypto.KeyGenerator`, each purpose
  with its own salt. Codes are 6 random digits. Nothing here is ever logged.
  """

  alias Plug.Crypto.KeyGenerator

  @email_salt "simplefit sponsor contact email v1"
  @code_salt "simplefit sponsor contact code v1"

  @doc "A new 6-digit code."
  @spec new_code() :: String.t()
  def new_code,
    do: :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() |> rem(1_000_000) |> pad()

  @doc "The digest of a (normalized) contact email."
  @spec email_digest(String.t()) :: binary()
  def email_digest(email) when is_binary(email), do: mac(@email_salt, email)

  @doc "The verifier of `code` for one code row."
  @spec code_verifier(Ecto.UUID.t(), String.t()) :: binary()
  def code_verifier(code_id, code) when is_binary(code),
    do: mac(@code_salt, code_id <> <<0>> <> code)

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  defp mac(salt, data),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        KeyGenerator.generate(secret_key_base(), salt,
          length: 32,
          digest: :sha256,
          cache: Plug.Crypto.Keys
        ),
        data
      )

  defp secret_key_base do
    case Application.get_env(:simple_fit, SimpleFit.Sponsors, [])[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 64 ->
        secret

      _missing ->
        raise ArgumentError,
              "SimpleFit.Sponsors: secret_key_base must be at least 64 bytes (SECRET_KEY_BASE)"
    end
  end
end
