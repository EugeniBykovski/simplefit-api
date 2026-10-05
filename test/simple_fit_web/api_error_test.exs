defmodule SimpleFitWeb.APIErrorTest do
  use ExUnit.Case, async: true

  alias SimpleFitWeb.APIError

  @expected %{
    "bad_request" => 400,
    "unauthorized" => 401,
    "forbidden" => 403,
    "not_found" => 404,
    "not_acceptable" => 406,
    "conflict" => 409,
    "payload_too_large" => 413,
    "unsupported_media_type" => 415,
    "validation_error" => 422,
    "rate_limited" => 429,
    "internal_error" => 500,
    "service_unavailable" => 503
  }

  test "the catalog maps every code to its HTTP status, both ways" do
    assert Map.new(APIError.codes(), &{&1, APIError.status(&1)}) == @expected

    for {code, status} <- @expected do
      assert APIError.code_for_status(status) == code
    end
  end

  test "codes are unique snake_case strings" do
    codes = APIError.codes()

    assert codes == Enum.uniq(codes)
    assert Enum.all?(codes, &Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1))
  end

  test "statuses outside the catalog get a code derived from the reason phrase" do
    assert APIError.code_for_status(405) == "method_not_allowed"
    assert APIError.code_for_status(502) == "bad_gateway"

    assert APIError.envelope(405).error.message == "Method Not Allowed"
  end

  test "envelope/2 builds the full contract shape" do
    assert APIError.envelope(422,
             details: %{fields: %{email: ["can't be blank"]}},
             request_id: "abc123"
           ) == %{
             error: %{
               code: "validation_error",
               message: "Request validation failed",
               details: %{fields: %{email: ["can't be blank"]}},
               request_id: "abc123"
             }
           }
  end

  test "envelope/2 accepts an explicit code" do
    assert APIError.envelope(400, code: "validation_error").error.code == "validation_error"
  end

  describe "send_error/3" do
    defp request_conn do
      Phoenix.ConnTest.build_conn() |> Plug.RequestId.call(Plug.RequestId.init([]))
    end

    test "sends the catalogued envelope with the conn's request id and halts" do
      conn = APIError.send_error(request_conn(), "conflict")

      assert conn.halted
      assert conn.status == 409
      assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      [request_id] = Plug.Conn.get_resp_header(conn, "x-request-id")

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "code" => "conflict",
                 "message" => APIError.message("conflict"),
                 "details" => %{},
                 "request_id" => request_id
               }
             }
    end

    test "sets retry-after when given" do
      conn = APIError.send_error(request_conn(), "rate_limited", retry_after: 30)

      assert conn.status == 429
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["30"]
    end

    test "only accepts catalogued codes" do
      assert_raise FunctionClauseError, fn ->
        APIError.send_error(request_conn(), "something_new")
      end
    end
  end
end
