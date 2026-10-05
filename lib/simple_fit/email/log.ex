defmodule SimpleFit.Email.Log do
  @moduledoc """
  Development `SimpleFit.Email` adapter: logs that a message would be sent
  (recipient count and subject, never the body) instead of sending it.

  Selected in development when `RESEND_API_KEY` is not set. Production
  configuration never selects it.
  """

  @behaviour SimpleFit.Email

  require Logger

  @impl true
  def deliver(message, _config, _opts) do
    Logger.info(
      "email not sent (development log adapter): #{length(message.to)} recipient(s), " <>
        "subject #{inspect(message.subject)}"
    )

    {:ok, %{id: "log-" <> Integer.to_string(System.unique_integer([:positive]))}}
  end
end
