defmodule SimpleFit.Observability.RequestLogger do
  @moduledoc """
  One structured log event per HTTP request, replacing Phoenix's plain-text
  request logs:

      request completed  method=GET route=/api/health status=200 duration_ms=3 request_id=...

    * `route` is the router's path template (`/api/v1/fighters/:id`), never
      the raw path or query string, so logs stay low-cardinality and free of
      identifiers, tokens or other values a client put in the URL. Unmatched
      requests log `route=nil`.
    * Bodies, params and headers are never logged.

  Built on Phoenix telemetry (`[:phoenix, :router_dispatch, :start]` sets
  `route` in the request's Logger metadata; `[:phoenix, :endpoint, :stop]`
  logs the outcome), so timing comes from `Plug.Telemetry` rather than a
  second clock.
  """

  require Logger

  @handler_id {__MODULE__, :request}

  @doc "Attaches the telemetry handlers (idempotent)."
  @spec attach() :: :ok
  def attach do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        [
          [:phoenix, :endpoint, :start],
          [:phoenix, :router_dispatch, :start],
          [:phoenix, :endpoint, :stop]
        ],
        &__MODULE__.handle_event/4,
        nil
      )
  end

  @doc false
  # Bandit reuses the process across keep-alive requests: reset per request.
  def handle_event([:phoenix, :endpoint, :start], _measurements, _metadata, _config) do
    Logger.metadata(route: nil)
  end

  def handle_event([:phoenix, :router_dispatch, :start], _measurements, metadata, _config) do
    Logger.metadata(route: metadata[:route])
  end

  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    Logger.info("request completed",
      method: conn.method,
      route: Logger.metadata()[:route],
      status: conn.status,
      duration_ms: System.convert_time_unit(duration, :native, :microsecond) / 1000
    )
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
