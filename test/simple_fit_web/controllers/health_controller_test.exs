defmodule SimpleFitWeb.HealthControllerTest do
  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias SimpleFitWeb.ApiSpec

  describe "GET /api/health" do
    test "returns ok with the service name", %{conn: conn} do
      conn = get(conn, ~p"/api/health")

      assert json_response(conn, 200) == %{"status" => "ok", "service" => "simplefit-api"}
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end

    test "conforms to the OpenAPI contract", %{conn: conn} do
      conn = get(conn, ~p"/api/health")

      assert_schema(json_response(conn, 200), "HealthResponse", ApiSpec.spec())
    end

    test "returns a request id header", %{conn: conn} do
      conn = get(conn, ~p"/api/health")

      assert [request_id] = get_resp_header(conn, "x-request-id")
      assert byte_size(request_id) > 0
    end

    test "sends hardened API security headers", %{conn: conn} do
      conn = get(conn, ~p"/api/health")

      assert get_resp_header(conn, "content-security-policy") == [
               "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
             ]

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end

    test "sends no CORS headers by default", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> get(~p"/api/health")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end
end
