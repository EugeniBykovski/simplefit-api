defmodule SimpleFitWeb.CORSTest do
  @moduledoc """
  The API's cross-origin policy, end to end through the endpoint. The test
  allow-list is `["http://localhost:3000"]` (config/test.exs).
  """

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias SimpleFitWeb.{ApiSpec, CORS}

  @allowed "http://localhost:3000"

  defp preflight(conn, origin, method \\ "GET", headers \\ nil) do
    conn =
      conn
      |> put_req_header("origin", origin)
      |> put_req_header("access-control-request-method", method)

    conn =
      if headers, do: put_req_header(conn, "access-control-request-headers", headers), else: conn

    options(conn, "/api/health")
  end

  describe "actual requests" do
    test "an allowed origin can read the response and the request id", %{conn: conn} do
      conn = conn |> put_req_header("origin", @allowed) |> get("/api/health")

      assert json_response(conn, 200)["status"] == "ok"
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert get_resp_header(conn, "access-control-expose-headers") == ["x-request-id"]
      assert get_resp_header(conn, "vary") == ["origin"]
      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end

    test "an unknown origin gets no CORS headers, so browsers block it", %{conn: conn} do
      conn = conn |> put_req_header("origin", "https://evil.example") |> get("/api/health")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "vary") == ["origin"]
    end

    test "requests without an Origin (mobile, server) are unaffected", %{conn: conn} do
      conn = get(conn, "/api/health")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "error responses to an allowed origin are readable too", %{conn: conn} do
      conn = conn |> put_req_header("origin", @allowed) |> get("/api/does-not-exist")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
    end
  end

  describe "preflight" do
    test "is answered for an allowed origin, method and headers", %{conn: conn} do
      conn = preflight(conn, @allowed, "POST", "Content-Type, Authorization")

      assert conn.status == 204
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]

      assert get_resp_header(conn, "access-control-allow-methods") == [
               "GET, POST, PUT, PATCH, DELETE"
             ]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "accept, accept-language, authorization, content-type"
             ]

      assert get_resp_header(conn, "access-control-max-age") == ["600"]
      assert get_resp_header(conn, "access-control-allow-credentials") == []
      assert [_request_id] = get_resp_header(conn, "x-request-id")
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "is refused for an unknown origin with the error envelope", %{conn: conn} do
      conn = preflight(conn, "http://localhost:3001")

      body = json_response(conn, 403)
      assert body["error"]["code"] == "forbidden"
      assert_schema(body, "ErrorResponse", ApiSpec.spec())
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "is refused for a method or header outside the policy", %{conn: conn} do
      assert conn |> preflight(@allowed, "TRACE") |> json_response(403)
      assert conn |> preflight(@allowed, "GET", "x-custom-header") |> json_response(403)
    end

    test "an OPTIONS request that is not a preflight is routed as usual", %{conn: conn} do
      conn = conn |> put_req_header("origin", @allowed) |> options("/api/health")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "parse_origins!/2" do
    test "parses an explicit, comma-separated list" do
      assert CORS.parse_origins!(" https://app.example.com, http://localhost:3000 ,") == [
               "https://app.example.com",
               "http://localhost:3000"
             ]
    end

    test "normalises case and removes duplicates" do
      assert CORS.parse_origins!("HTTPS://App.Example.com,https://app.example.com") == [
               "https://app.example.com"
             ]
    end

    test "unset or blank allows no origin (fail closed)" do
      assert CORS.parse_origins!(nil) == []
      assert CORS.parse_origins!("  ") == []
    end

    test "rejects wildcards, paths, trailing slashes and other non-origins" do
      for bad <- [
            "*",
            "https://*.example.com",
            "https://app.example.com/",
            "app.example.com",
            "https://app.example.com/path",
            "ftp://example.com",
            "https://user@example.com"
          ] do
        assert_raise ArgumentError, ~r/is not an exact origin/, fn -> CORS.parse_origins!(bad) end
      end
    end

    test "requires https when asked (production)" do
      assert CORS.parse_origins!("https://app.example.com", require_https: true) == [
               "https://app.example.com"
             ]

      assert_raise ArgumentError, ~r/must use https/, fn ->
        CORS.parse_origins!("http://app.example.com", require_https: true)
      end
    end
  end
end
