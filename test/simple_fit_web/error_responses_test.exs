defmodule SimpleFitWeb.ErrorResponsesTest do
  @moduledoc """
  End-to-end checks that errors raised anywhere in the endpoint are rendered
  with the API error envelope.
  """

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias SimpleFitWeb.ApiSpec

  defp assert_error_envelope(%Plug.Conn{} = conn, status, code) do
    assert_envelope_body(json_response(conn, status), code)
  end

  # For exceptions Phoenix renders and then re-raises (so the adapter can log
  # them), `assert_error_sent/2` captures the rendered response.
  defp assert_error_envelope({status, headers, body}, expected_status, code) do
    assert status == expected_status
    assert {"content-type", "application/json" <> _} = List.keyfind(headers, "content-type", 0)
    assert {"x-request-id", request_id} = List.keyfind(headers, "x-request-id", 0)
    assert {"x-content-type-options", "nosniff"} in headers

    body = assert_envelope_body(Jason.decode!(body), code)
    assert body["error"]["request_id"] == request_id
    body
  end

  defp assert_envelope_body(body, code) do
    assert %{"error" => %{"code" => ^code, "message" => message, "details" => %{}}} = body
    assert is_binary(message)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())

    body
  end

  test "unknown routes return not_found with the request id", %{conn: conn} do
    conn = get(conn, "/api/does-not-exist")

    body = assert_error_envelope(conn, 404, "not_found")
    assert [request_id] = get_resp_header(conn, "x-request-id")
    assert body["error"]["request_id"] == request_id
  end

  test "unsupported methods on known paths return not_found", %{conn: conn} do
    conn = delete(conn, "/api/health")

    assert_error_envelope(conn, 404, "not_found")
  end

  test "malformed JSON returns bad_request without echoing the body", %{conn: conn} do
    response =
      assert_error_sent 400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/health", ~s({"broken": tru))
      end

    body = assert_error_envelope(response, 400, "bad_request")
    refute Jason.encode!(body) =~ "broken"
  end

  test "non-JSON request bodies return unsupported_media_type", %{conn: conn} do
    response =
      assert_error_sent 415, fn ->
        conn
        |> put_req_header("content-type", "text/plain")
        |> post("/api/health", "hello")
      end

    assert_error_envelope(response, 415, "unsupported_media_type")
  end

  test "non-JSON Accept headers return not_acceptable", %{conn: conn} do
    response =
      assert_error_sent 406, fn ->
        conn
        |> put_req_header("accept", "text/html")
        |> get("/api/health")
      end

    assert_error_envelope(response, 406, "not_acceptable")
  end

  test "error responses carry the API security headers", %{conn: conn} do
    conn = get(conn, "/api/does-not-exist")

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
  end
end
