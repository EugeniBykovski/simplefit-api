defmodule SimpleFitWeb.EntryPrivacyTest do
  # Raises the global log level: not async.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias SimpleFit.Accounts

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "entry resolution logs the routing outcome only, at info, never identifiers or tokens" do
    {:ok, user} =
      Accounts.register_user(:google, "entry-log-#{System.unique_integer([:positive])}")

    {:ok, credentials} = Accounts.create_session(user)

    log =
      capture_log([level: :info, metadata: [:intent, :destination, :reason]], fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer " <> credentials.access_token)
        |> get("/api/v1/me/entry?intent=fighter&returnTo=https%3A%2F%2Fevil.example")
        |> json_response(200)
      end)

    assert log =~ "[info] entry resolved"
    assert log =~ "intent=fighter"
    assert log =~ "destination=account_registration"
    assert log =~ "reason=account_registration_incomplete"
    refute log =~ "[error]"
    refute log =~ user.id
    refute log =~ credentials.access_token
    refute log =~ "evil.example"
  end
end
