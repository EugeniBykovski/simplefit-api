defmodule SimpleFit.Email.Resend do
  @moduledoc """
  `SimpleFit.Email` adapter for Resend (`POST https://api.resend.com/emails`),
  using the canonical `SimpleFit.HTTP` client. No vendor SDK.

  ## Configuration (`config :simple_fit, SimpleFit.Email`)

    * `:api_key` - Resend API key (`RESEND_API_KEY`), required
    * `:from` - default sender (`EMAIL_FROM`), required unless every message
      sets `:from`
    * `:req_options` - extra Req options; tests use
      `plug: {Req.Test, SimpleFit.Email.Resend}`

  Missing configuration returns `{:error, :configuration_error}` without
  making a request (fail closed). The API key travels only in the
  `authorization` header and is never logged.
  """

  @behaviour SimpleFit.Email

  require Logger

  alias SimpleFit.Email.Message
  alias SimpleFit.HTTP

  @base_url "https://api.resend.com"
  @provider "resend"

  @impl true
  def deliver(%Message{} = message, config, opts) do
    with {:ok, api_key} <- fetch_config(config, :api_key),
         {:ok, from} <- fetch_from(message, config) do
      request =
        HTTP.new(
          [
            base_url: @base_url,
            auth: {:bearer, api_key},
            headers: idempotency_header(opts),
            json: payload(message, from)
          ] ++ Keyword.get(config, :req_options, [])
        )

      request
      |> Req.post(url: "/emails")
      |> HTTP.normalize(@provider)
      |> receipt()
    end
  end

  defp payload(message, from) do
    %{from: from, to: message.to, subject: message.subject}
    |> put_present(:text, message.text)
    |> put_present(:html, message.html)
    |> put_present(:reply_to, message.reply_to)
  end

  defp receipt({:ok, %Req.Response{body: %{"id" => id}}}) when is_binary(id), do: {:ok, %{id: id}}

  defp receipt({:ok, _unexpected}) do
    Logger.warning("provider returned an unexpected response", provider: @provider)
    {:error, :unavailable}
  end

  defp receipt({:error, _reason} = error), do: error

  defp fetch_from(%Message{from: from}, _config) when is_binary(from), do: {:ok, from}
  defp fetch_from(_message, config), do: fetch_config(config, :from)

  defp fetch_config(config, key) do
    case config[key] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _missing ->
        Logger.error("email is not configured", provider: @provider, missing: [key])
        {:error, :configuration_error}
    end
  end

  defp idempotency_header(opts) do
    case opts[:idempotency_key] do
      key when is_binary(key) and byte_size(key) in 1..256 -> [{"idempotency-key", key}]
      _none -> []
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
