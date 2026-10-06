defmodule SimpleFitWeb.SessionPrivacyTest do
  @moduledoc """
  Session secrets never leave the request: not in logs (at debug level), not
  in Sentry, not in traces, not in error bodies.
  """

  # Not async: changes the global log level and collects spans and Sentry reports.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  require Record

  alias SimpleFit.Accounts
  alias SimpleFitWeb.SessionTransport

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  setup do
    {:ok, user} = Accounts.register_user(:email, "privacy@example.com")
    {:ok, credentials} = Accounts.create_session(user)
    %{credentials: credentials}
  end

  defp secrets(c, extra) do
    hash = :crypto.hash(:sha256, c.refresh_token)

    [
      c.access_token,
      c.refresh_token,
      Base.encode16(hash, case: :lower),
      Base.encode16(hash),
      Base.encode64(hash),
      # How Ecto's debug query log would print the verifier.
      inspect(hash, limit: :infinity)
      | extra
    ]
  end

  # Every authenticated and session flow, successful and failing.
  defp exercise(c) do
    me =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> c.access_token)
      |> get(~p"/api/me")

    refreshed =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/auth/session/refresh", Jason.encode!(%{refresh_token: c.refresh_token}))

    %{"refresh_token" => next_refresh, "access_token" => next_access} =
      Jason.decode!(refreshed.resp_body)

    cookie =
      build_conn()
      |> put_req_cookie(SessionTransport.cookie_name(), next_refresh)
      |> put_req_header("origin", "http://localhost:3000")
      |> put_req_header("x-simplefit-csrf", "1")
      |> post(~p"/api/auth/session/refresh")

    cookie_value = cookie.resp_cookies[SessionTransport.cookie_name()].value

    # Replaying the first token is reuse: it revokes the session.
    replay =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/auth/session/refresh", Jason.encode!(%{refresh_token: c.refresh_token}))

    logout =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> next_access)
      |> post(~p"/api/auth/logout")

    rejected =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> next_access)
      |> get(~p"/api/me")

    %{
      conns: [me, refreshed, replay, cookie, logout, rejected],
      issued: [next_refresh, next_access, cookie_value]
    }
  end

  test "no secret reaches the logs, even at debug level", %{credentials: c} do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {%{issued: issued}, log} = with_log([level: :debug], fn -> exercise(c) end)

    assert log =~ "request completed"

    for secret <- secrets(c, issued) do
      refute log =~ secret
    end
  end

  test "error bodies carry no secret", %{credentials: c} do
    %{conns: conns, issued: issued} = exercise(c)

    for conn <- conns, conn.status >= 400, secret <- secrets(c, issued) do
      refute conn.resp_body =~ secret
    end
  end

  test "expected authentication failures are not sent to Sentry", %{credentials: c} do
    Sentry.Test.start_collecting_sentry_reports()
    exercise(c)
    assert Sentry.Test.pop_sentry_reports() == []
  end

  test "traces keep no credential, cookie or verifier", %{credentials: c} do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    # An incoming request as Bandit reports it, with the real credentials.
    conn =
      Plug.Test.conn(:post, "/api/auth/session/refresh")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> c.access_token)
      |> Plug.Conn.put_req_header("cookie", "__Secure-sf_refresh=" <> c.refresh_token)

    :telemetry.execute([:bandit, :request, :start], %{monotonic_time: System.monotonic_time()}, %{
      conn: conn
    })

    :telemetry.execute(
      [:bandit, :request, :stop],
      %{monotonic_time: System.monotonic_time(), duration: 1},
      %{conn: %{conn | status: 200}}
    )

    %{issued: issued} = exercise(c)
    spans = collect_spans([])

    assert spans != []

    for span_record <- spans, secret <- secrets(c, issued) do
      refute inspect(span(span_record, :attributes), limit: :infinity) =~ secret
      refute inspect(span(span_record, :name)) =~ secret
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
