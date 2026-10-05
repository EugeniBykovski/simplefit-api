defmodule SimpleFitWeb.CORSConfigTest do
  # Changes application env: not async.
  use SimpleFitWeb.ConnCase, async: false

  @key SimpleFitWeb.CORS

  setup do
    original = Application.get_env(:simple_fit, @key)
    on_exit(fn -> Application.put_env(:simple_fit, @key, original) end)
  end

  test "the policy follows the configured allow-list at runtime", %{conn: conn} do
    Application.put_env(:simple_fit, @key, allowed_origins: ["https://app.example.com"])

    allowed = conn |> put_req_header("origin", "https://app.example.com") |> get("/api/health")
    assert get_resp_header(allowed, "access-control-allow-origin") == ["https://app.example.com"]

    local =
      build_conn() |> put_req_header("origin", "http://localhost:3000") |> get("/api/health")

    assert get_resp_header(local, "access-control-allow-origin") == []
  end

  test "an empty allow-list blocks every browser origin", %{conn: conn} do
    Application.put_env(:simple_fit, @key, allowed_origins: [])

    conn =
      conn
      |> put_req_header("origin", "http://localhost:3000")
      |> put_req_header("access-control-request-method", "GET")
      |> options("/api/health")

    assert json_response(conn, 403)["error"]["code"] == "forbidden"
  end
end
