defmodule SimpleFitWeb.GoogleAuthNotConfiguredTest do
  @moduledoc """
  Without GOOGLE_OAUTH_CLIENT_IDS Google sign-in fails closed with the public
  service_unavailable error, and the cause is visible only as a bounded
  reason in the server log (ADR 0013).
  """

  # Changes application env: not async.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import SimpleFit.GoogleTokens

  alias SimpleFit.Identity.Google

  setup do
    original = Application.get_env(:simple_fit, Google)
    Application.put_env(:simple_fit, Google, Keyword.put(original, :client_ids, []))
    on_exit(fn -> Application.put_env(:simple_fit, Google, original) end)
    reset()
    :ok
  end

  test "fails closed with service_unavailable and logs only the reason", %{conn: conn} do
    token = valid_token("4242", %{"email" => "secret.person@example.com"})

    ref =
      :telemetry_test.attach_event_handlers(self(), [[:simple_fit, :auth, :google, :unavailable]])

    {conn, log} =
      with_log([level: :warning], fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/google", Jason.encode!(%{id_token: token}))
      end)

    body = json_response(conn, 503)
    assert body["error"]["code"] == "service_unavailable"
    assert body["error"]["message"] == "The service is temporarily unavailable"
    assert body["error"]["details"] == %{}
    refute conn.resp_body =~ "not_configured"
    refute conn.resp_body =~ "GOOGLE_OAUTH_CLIENT_IDS"

    assert log =~ "google sign-in unavailable"
    assert log =~ "reason=not_configured"

    assert_received {[:simple_fit, :auth, :google, :unavailable], ^ref, %{count: 1},
                     %{reason: :not_configured}}

    [_header, payload, signature] = String.split(token, ".")

    for secret <- [token, payload, signature, "4242", "secret.person@example.com", web_client()] do
      refute log =~ secret
      refute conn.resp_body =~ secret
    end
  end

  test "the boot check warns about an empty allow-list without failing" do
    log = capture_log([level: :warning], fn -> assert Google.warn_if_not_configured() == :ok end)

    assert log =~ "google sign-in not configured"
    assert log =~ "reason=not_configured"
  end

  test "the boot check is silent and never logs client ids when configured" do
    Application.put_env(:simple_fit, Google, client_ids: [web_client()])

    log = capture_log([level: :debug], fn -> assert Google.warn_if_not_configured() == :ok end)

    assert log == ""
  end
end
