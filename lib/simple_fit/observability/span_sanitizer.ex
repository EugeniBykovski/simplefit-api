defmodule SimpleFit.Observability.SpanSanitizer do
  @moduledoc """
  OpenTelemetry span processor that removes sensitive attributes from every
  span when it starts, whichever instrumentation created it. It runs first in
  the processor chain (`config :opentelemetry, processors:`); the SDK passes
  its result to the batch processor.

  Removed:

    * `url.query`: raw query strings can carry tokens, OAuth codes or
      presigned-URL signatures (`opentelemetry_bandit` always records it)
    * `client.address`, `client.port`, `network.peer.address`,
      `network.peer.port`: client IP addresses are personal data
    * `db.statement`, `db.query.text`: SQL text (already disabled for Ecto;
      defence in depth)
    * any `http.request.header.*` / `http.response.header.*` attribute
    * the query and fragment of `url.full` (`opentelemetry_req`): outbound
      URLs keep scheme, host and path only

  Exception events recorded later in a span's life (type and message) are
  server-side diagnostics, governed like logs; see ADR 0008.
  """

  @behaviour :otel_span_processor

  require Record

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @dropped [
    :"url.query",
    :"client.address",
    :"client.port",
    :"network.peer.address",
    :"network.peer.port",
    :"db.statement",
    :"db.query.text"
  ]

  @header_prefixes ["http.request.header.", "http.response.header."]

  @impl :otel_span_processor
  def on_start(_ctx, span, _config) do
    case span(span, :attributes) do
      :undefined -> span
      attributes -> span(span, attributes: sanitize_attributes(attributes))
    end
  end

  @impl :otel_span_processor
  def on_end(_span, _config), do: true

  @impl :otel_span_processor
  def force_flush(_config), do: :ok

  @doc """
  Returns `attributes` (an `otel_attributes` record) without sensitive keys.
  Limits are preserved.
  """
  @spec sanitize_attributes(tuple()) :: tuple()
  def sanitize_attributes({:attributes, count_limit, value_length_limit, dropped, map}) do
    {:attributes, count_limit, value_length_limit, dropped, sanitize_map(map)}
  end

  @doc "Removes sensitive keys from an attribute map."
  @spec sanitize_map(map()) :: map()
  def sanitize_map(map) do
    map
    |> Map.drop(@dropped)
    |> Map.reject(fn {key, _value} -> header?(key) end)
    |> Map.new(fn
      {:"url.full", url} when is_binary(url) -> {:"url.full", strip_query(url)}
      pair -> pair
    end)
  end

  defp header?(key) do
    key = to_string(key)
    Enum.any?(@header_prefixes, &String.starts_with?(key, &1))
  end

  defp strip_query(url) do
    %URI{URI.parse(url) | query: nil, fragment: nil, userinfo: nil} |> URI.to_string()
  rescue
    _error -> "[unparseable url]"
  end
end
