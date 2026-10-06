defmodule SimpleFit.Email.JobPayload do
  @moduledoc """
  Seals a `SimpleFit.Email.Message` for the Oban `mailers` queue (ADR 0011).

  Job arguments are stored in PostgreSQL (`oban_jobs`) until pruned and are
  visible to anyone who can inspect jobs or read backups. Transactional
  emails carry personal data and, for verification and recovery, one-time
  codes and credential-bearing URLs. The job therefore stores only
  `Plug.Crypto.encrypt/4` ciphertext: XChaCha20-Poly1305 authenticated
  encryption with a random 192-bit nonce per payload, under a 256-bit key
  derived from `SECRET_KEY_BASE` (PBKDF2-HMAC-SHA256) with a dedicated salt.
  The worker opens it just before delivery.

  A sealed payload is valid for 7 days, longer than any job's retry window.
  Rotating `SECRET_KEY_BASE` makes payloads sealed before the rotation
  unreadable: those jobs are cancelled instead of being sent.
  """

  alias SimpleFit.Email.Message

  @salt "simplefit email job payload v1"
  @max_age 7 * 24 * 60 * 60

  @doc "Encrypts `message` for a job argument."
  @spec seal(Message.t()) :: {:ok, String.t()} | {:error, :configuration_error}
  def seal(%Message{} = message) do
    with {:ok, key_base} <- key_base() do
      {:ok, Plug.Crypto.encrypt(key_base, @salt, Message.to_map(message), max_age: @max_age)}
    end
  end

  @doc "Decrypts and re-validates a sealed message."
  @spec open(term()) :: {:ok, Message.t()} | {:error, :invalid_request | :configuration_error}
  def open(sealed) when is_binary(sealed) do
    with {:ok, key_base} <- key_base(),
         {:ok, map} when is_map(map) <-
           Plug.Crypto.decrypt(key_base, @salt, sealed, max_age: @max_age) do
      Message.from_map(map)
    else
      {:error, :configuration_error} -> {:error, :configuration_error}
      _invalid_or_expired -> {:error, :invalid_request}
    end
  end

  def open(_sealed), do: {:error, :invalid_request}

  defp key_base do
    case Application.get_env(:simple_fit, SimpleFit.Email, [])[:payload_key_base] do
      key when is_binary(key) and byte_size(key) >= 64 -> {:ok, key}
      _missing -> {:error, :configuration_error}
    end
  end
end
