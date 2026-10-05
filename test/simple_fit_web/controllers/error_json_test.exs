defmodule SimpleFitWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias SimpleFitWeb.ErrorJSON

  test "renders 404 as not_found" do
    assert ErrorJSON.render("404.json", %{}) == %{
             error: %{
               code: "not_found",
               message: "The requested resource was not found",
               details: %{},
               request_id: nil
             }
           }
  end

  test "renders 500 as internal_error without exposing the exception" do
    assigns = %{
      status: 500,
      kind: :error,
      reason: %RuntimeError{message: "database password is hunter2"},
      stack: [{SimpleFit.Secret, :leak, 0, [file: ~c"lib/simple_fit/secret.ex", line: 1]}]
    }

    rendered = ErrorJSON.render("500.json", assigns)

    assert rendered.error.code == "internal_error"
    assert rendered.error.message == "An unexpected error occurred"
    assert rendered.error.details == %{}

    encoded = Jason.encode!(rendered)
    refute encoded =~ "hunter2"
    refute encoded =~ "RuntimeError"
    refute encoded =~ "secret.ex"
  end

  test "uses the request id from the Logger metadata" do
    Logger.metadata(request_id: "req-from-logger")

    assert ErrorJSON.render("404.json", %{}).error.request_id == "req-from-logger"
  after
    Logger.metadata(request_id: nil)
  end

  test "prefers the request id on the conn's response headers" do
    Logger.metadata(request_id: "req-from-logger")

    conn = Plug.Conn.put_resp_header(%Plug.Conn{}, "x-request-id", "req-from-conn")

    assert ErrorJSON.render("404.json", %{conn: conn}).error.request_id == "req-from-conn"
  after
    Logger.metadata(request_id: nil)
  end

  test "derives the status from the template when no status is assigned" do
    assert ErrorJSON.render("503.json", %{}).error.code == "service_unavailable"
  end
end
