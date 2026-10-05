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
end
