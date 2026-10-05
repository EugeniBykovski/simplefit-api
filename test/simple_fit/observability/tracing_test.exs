defmodule SimpleFit.Observability.TracingTest do
  @moduledoc """
  The maintained instrumentation libraries, as configured, combined with
  SpanSanitizer: spans carry operational data only.
  """

  use SimpleFit.DataCase, async: false

  require Record
  require OpenTelemetry.Tracer, as: Tracer

  alias SimpleFit.Observability.SpanSanitizer

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  defp attributes(span_record) do
    {:attributes, _count, _length, _dropped, map} = span(span_record, :attributes)
    map
  end

  defp receive_span(name) do
    receive do
      {:span, span_record} ->
        if span(span_record, :name) == name, do: span_record, else: receive_span(name)
    after
      2_000 -> flunk("no span named #{inspect(name)}")
    end
  end

  test "incoming request spans drop the query string and client addresses" do
    conn =
      Plug.Test.conn(:get, "/api/health?token=SECRET-TOKEN")
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7")
      |> Plug.Conn.put_req_header("authorization", "Bearer SECRET-BEARER")

    :telemetry.execute([:bandit, :request, :start], %{monotonic_time: System.monotonic_time()}, %{
      conn: conn
    })

    :telemetry.execute(
      [:bandit, :request, :stop],
      %{monotonic_time: System.monotonic_time(), duration: 1},
      %{conn: %{conn | status: 200}}
    )

    attributes = attributes(receive_span(:GET))

    refute Map.has_key?(attributes, :"url.query")
    refute Map.has_key?(attributes, :"client.address")
    refute Map.has_key?(attributes, :"network.peer.address")
    assert attributes[:"url.path"] == "/api/health"
    refute inspect(attributes) =~ "SECRET"
  end

  test "database spans carry timing and table, never SQL or parameters" do
    Repo.query!("SELECT $1::text AS secret", ["SECRET-PARAM"])

    span_record = receive_span("simple_fit.repo.query")
    attributes = attributes(span_record)

    refute Map.has_key?(attributes, :"db.statement")
    refute inspect(attributes) =~ "SECRET-PARAM"
    refute inspect(attributes) =~ "SELECT"
  end

  test "outbound HTTP spans keep scheme, host and path only" do
    client =
      SimpleFit.HTTP.new(
        base_url: "https://api.vendor.test",
        plug: fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end,
        headers: [{"authorization", "Bearer SECRET-KEY"}]
      )

    {:ok, _response} =
      Req.get(client, url: "/v1/objects?api_key=SECRET-QUERY&X-Amz-Signature=sig")

    attributes = attributes(receive_span(:GET))

    assert attributes[:"url.full"] == "https://api.vendor.test/v1/objects"
    refute inspect(attributes) =~ "SECRET"
  end

  test "provider boundary spans record adapter and normalized result only" do
    message = %SimpleFit.Email.Message{
      to: ["athlete@example.com"],
      subject: "Private subject",
      text: "Private body"
    }

    SimpleFit.Email.deliver(message)

    attributes = attributes(receive_span("provider email.deliver"))
    assert attributes[:"simple_fit.provider.operation"] == "email.deliver"
    assert attributes[:"simple_fit.provider.result"] == :ok
    refute inspect(attributes) =~ "athlete@example.com"
    refute inspect(attributes) =~ "Private"
  end

  test "logs inside a span carry its trace and span ids" do
    Tracer.with_span "work" do
      metadata = Logger.metadata()
      assert is_binary(to_string(metadata[:otel_trace_id]))
      assert metadata[:otel_span_id]
    end
  end

  test "sanitize_map/1 removes every sensitive key" do
    assert SpanSanitizer.sanitize_map(%{
             "url.query": "a=1",
             "client.address": "1.2.3.4",
             "db.statement": "SELECT 1",
             "http.request.header.authorization": ["Bearer x"],
             "url.full": "https://h.test/p?q=1#f",
             "http.route": "/api/health"
           }) == %{"url.full": "https://h.test/p", "http.route": "/api/health"}
  end
end
