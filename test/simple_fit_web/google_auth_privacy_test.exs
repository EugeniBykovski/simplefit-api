defmodule SimpleFitWeb.GoogleAuthPrivacyTest do
  @moduledoc "Google ID tokens never leave the request (ADR 0013)."

  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import SimpleFit.GoogleTokens

  require Record

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  @events for e <- [:verified, :rejected, :unavailable, :rate_limited, :keys_unavailable],
              do: [:simple_fit, :auth, :google, e]

  setup do
    reset()
    stub_jwks(self())
    :ok
  end

  defp exercise do
    good = valid_token("8080", %{"email" => "secret.person@example.com"})
    bad = token(claims("8081", %{"aud" => "9-x.apps.googleusercontent.com"}))

    conns =
      for token <- [good, good, bad, "garbage." <> good] do
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/google", Jason.encode!(%{id_token: token}))
      end

    [_header, payload, signature] = String.split(good, ".")
    %{conns: conns, secrets: [good, bad, payload, signature, "secret.person@example.com"]}
  end

  test "no token or claim reaches the logs, even at debug level" do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {%{secrets: secrets}, log} = with_log([level: :debug], fn -> exercise() end)
    assert log =~ "request completed"

    for secret <- secrets, do: refute(log =~ secret)
  end

  test "telemetry carries bounded reasons only; no Sentry report; no token in error bodies" do
    ref = :telemetry_test.attach_event_handlers(self(), @events)
    Sentry.Test.start_collecting_sentry_reports()

    %{conns: conns, secrets: secrets} = exercise()

    events = collect(ref, [])
    assert Enum.any?(events, &match?({[_, _, _, :rejected], %{reason: :audience}}, &1))

    for {_event, metadata} <- events, secret <- secrets do
      refute inspect(metadata, limit: :infinity) =~ secret
    end

    for conn <- conns, conn.status >= 400, secret <- secrets do
      refute conn.resp_body =~ secret
    end

    assert Sentry.Test.pop_sentry_reports() == []
  end

  test "traces keep no token" do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    %{secrets: secrets} = exercise()

    for span_record <- collect_spans([]), secret <- secrets do
      refute inspect(span(span_record, :attributes), limit: :infinity) =~ secret
    end
  end

  test "id_token is a filtered parameter" do
    assert Phoenix.Logger.filter_values(%{"id_token" => "eyJ.secret.sig"}) ==
             %{"id_token" => "[FILTERED]"}
  end

  defp collect(ref, acc) do
    receive do
      {event, ^ref, _measurements, metadata} -> collect(ref, [{event, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp collect_spans(acc) do
    receive do
      {:span, span_record} -> collect_spans([span_record | acc])
    after
      200 -> acc
    end
  end
end
