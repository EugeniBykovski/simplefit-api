defmodule SimpleFit.Observability.RequestLoggerTest do
  # Raises the process log level; the handlers are global.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  @metadata [:request_id, :method, :route, :status, :duration_ms]

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  defp request_log(fun) do
    capture_log([level: :info, metadata: @metadata], fun)
    |> String.split("\n")
    |> Enum.find(&(&1 =~ "request completed"))
  end

  test "logs one structured event per request with the route template", %{conn: conn} do
    log =
      request_log(fn ->
        conn = get(conn, "/api/health?token=SECRET-TOKEN-VALUE")
        send(self(), {:request_id, hd(get_resp_header(conn, "x-request-id"))})
      end)

    assert_received {:request_id, request_id}
    assert log =~ "request_id=#{request_id}"
    assert log =~ "method=GET"
    assert log =~ "route=/api/health"
    assert log =~ "status=200"
    assert log =~ "duration_ms="
    refute log =~ "SECRET-TOKEN-VALUE"
    refute log =~ "token"
  end

  test "unmatched requests log no route and never the raw path", %{conn: conn} do
    log = request_log(fn -> get(conn, "/api/users/secret-path-segment") end)

    assert log =~ "status=404"
    refute log =~ "route="
    refute log =~ "secret-path-segment"
  end

  test "the route never leaks from a previous request on the same process", %{conn: conn} do
    get(conn, "/api/health")
    log = request_log(fn -> get(build_conn(), "/api/nope") end)

    refute log =~ "route=/api/health"
  end
end
