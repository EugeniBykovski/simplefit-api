defmodule SimpleFit.Email.Log do
  @moduledoc """
  Development `SimpleFit.Email` adapter: logs that a message would be sent
  (recipient count and part sizes only) instead of sending it. Subjects are
  not logged either: some carry one-time codes (E01). Inspect templates in
  the development email preview (`/dev/emails`) instead.

  Selected in development when `RESEND_API_KEY` is not set. Production
  configuration never selects it.
  """

  @behaviour SimpleFit.Email

  require Logger

  @impl true
  def deliver(message, _config, _opts) do
    Logger.info(
      "email not sent (development log adapter): #{length(message.to)} recipient(s), " <>
        "html #{byte_size(message.html || "")} bytes, text #{byte_size(message.text || "")} bytes"
    )

    {:ok, %{id: "log-" <> Integer.to_string(System.unique_integer([:positive]))}}
  end
end
