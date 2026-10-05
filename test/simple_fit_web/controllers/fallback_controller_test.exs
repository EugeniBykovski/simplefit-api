defmodule SimpleFitWeb.FallbackControllerTest do
  @moduledoc """
  The mapping from context results to the public error envelope. Exercised
  directly on a conn (no throwaway endpoint), with the request id assigned by
  `Plug.RequestId` as in the real endpoint.
  """

  use SimpleFitWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions

  alias SimpleFitWeb.{ApiSpec, FallbackController}

  setup %{conn: conn} do
    {:ok, conn: Plug.RequestId.call(conn, Plug.RequestId.init([]))}
  end

  defp error_body(conn, status, code) do
    assert conn.halted
    body = json_response(conn, status)
    assert %{"error" => %{"code" => ^code, "request_id" => request_id}} = body
    assert [^request_id] = get_resp_header(conn, "x-request-id")
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    body
  end

  test "an invalid changeset becomes validation_error with fields and field_codes", %{conn: conn} do
    changeset =
      {%{}, %{email: :string, name: :string}}
      |> Ecto.Changeset.cast(%{"email" => "x"}, [:email, :name])
      |> Ecto.Changeset.validate_required([:name])
      |> Ecto.Changeset.validate_format(:email, ~r/@/)

    body =
      conn |> FallbackController.call({:error, changeset}) |> error_body(422, "validation_error")

    assert body["error"]["message"] == "Request validation failed"

    assert body["error"]["details"] == %{
             "fields" => %{"email" => ["has invalid format"], "name" => ["can't be blank"]},
             "field_codes" => %{"email" => ["invalid_format"], "name" => ["required"]}
           }

    assert_schema(body["error"]["details"], "ValidationErrorDetails", ApiSpec.spec())
  end

  test "domain reasons map to their catalogued codes", %{conn: conn} do
    for {reason, status} <- [not_found: 404, forbidden: 403, conflict: 409] do
      body = conn |> FallbackController.call({:error, reason}) |> error_body(status, "#{reason}")
      assert body["error"]["details"] == %{}
    end
  end

  test "provider failures never become client 401 or 429", %{conn: conn} do
    capture_log(fn ->
      for reason <- [:timeout, :unavailable, :rate_limited] do
        conn
        |> FallbackController.call({:error, reason})
        |> error_body(503, "service_unavailable")
      end

      for reason <- [:unauthorized, :invalid_request, :configuration_error] do
        conn |> FallbackController.call({:error, reason}) |> error_body(500, "internal_error")
      end
    end)
  end

  test "unexpected reasons fail safely and are logged with the request id", %{conn: conn} do
    reason = {:db_failure, "password=hunter2 at /srv/app/lib/repo.ex"}

    log =
      capture_log([metadata: [:request_id]], fn ->
        Logger.metadata(request_id: hd(get_resp_header(conn, "x-request-id")))

        body =
          conn |> FallbackController.call({:error, reason}) |> error_body(500, "internal_error")

        assert body["error"]["message"] == "An unexpected error occurred"
        refute Jason.encode!(body) =~ "hunter2"
        refute Jason.encode!(body) =~ "repo.ex"
      end)

    assert log =~ "unhandled error result"
    assert log =~ hd(get_resp_header(conn, "x-request-id"))
  end
end
