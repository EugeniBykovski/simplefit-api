defmodule SimpleFitWeb.EmailAuthPrivacyTest do
  @moduledoc """
  Email authentication secrets and addresses never leave the request
  (ADR 0012): not in logs (at debug level), telemetry, Sentry, error bodies
  or job arguments.
  """

  # Not async: changes the global log level and collects Sentry reports.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts.EmailAuth.Secrets

  @email "private.person@example.com"
  @events for e <- [:requested, :sent, :verified, :rejected, :rate_limited],
              do: [:simple_fit, :auth, :email, e]

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  # Every flow: registration (code, wrong code, link replay, status),
  # sign-in (request, wrong code, success, replay) and throttling.
  defp exercise do
    registration = post_json("/api/auth/email/registrations", %{email: @email})
    %{"registration_token" => token} = Jason.decode!(registration.resp_body)
    e01 = last_email_to(@email)

    conns = [
      registration,
      post_json("/api/auth/email/registrations", %{email: @email}),
      post_json("/api/auth/email/registrations/verify", %{
        registration_token: token,
        code: "000000"
      }),
      post_json("/api/auth/email/registrations/verify", %{
        registration_token: token,
        code: code_from(e01)
      }),
      post_json("/api/auth/email/registrations/status", %{registration_token: token}),
      post_json("/api/auth/email/verification-links/verify", %{token: link_token_from(e01)})
    ]

    reset_rate_limits()
    sign_in = post_json("/api/auth/email/sign-in", %{email: @email})
    e17 = last_email_to(@email)

    conns =
      conns ++
        [
          sign_in,
          post_json("/api/auth/email/sign-in/verify", %{email: @email, code: "000000"}),
          post_json("/api/auth/email/sign-in/verify", %{email: @email, code: code_from(e17)}),
          post_json("/api/auth/email/sign-in/verify", %{email: @email, code: code_from(e17)})
        ]

    secrets = [
      @email,
      "private.person",
      code_from(e01),
      code_from(e17),
      link_token_from(e01),
      token,
      e01.text,
      Base.encode16(Secrets.target_digest(@email), case: :lower),
      inspect(Secrets.target_digest(@email), limit: :infinity)
    ]

    %{conns: conns, secrets: secrets}
  end

  test "no address, code, token or digest reaches the logs, even at debug level" do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {%{secrets: secrets}, log} = with_log([level: :debug], fn -> exercise() end)

    assert log =~ "request completed"

    for secret <- secrets do
      refute log =~ secret
    end
  end

  test "telemetry carries the purpose and outcome only" do
    ref = :telemetry_test.attach_event_handlers(self(), @events)
    %{secrets: secrets} = exercise()

    events = collect(ref, [])
    assert Enum.any?(events, &match?({[_, _, _, :verified], %{purpose: :sign_in}}, &1))
    assert Enum.any?(events, &match?({[_, _, _, :rejected], %{reason: :code_invalid}}, &1))

    for {_event, metadata} <- events, secret <- secrets do
      refute inspect(metadata, limit: :infinity) =~ secret
    end
  end

  test "error bodies and Oban job arguments carry no secret; no Sentry report" do
    Sentry.Test.start_collecting_sentry_reports()
    %{conns: conns, secrets: secrets} = exercise()

    for conn <- conns, conn.status >= 400, secret <- secrets do
      refute conn.resp_body =~ secret
    end

    jobs = inspect(SimpleFit.Repo.all(Oban.Job), limit: :infinity)

    for secret <- secrets do
      refute jobs =~ secret
    end

    assert Sentry.Test.pop_sentry_reports() == []
  end

  defp collect(ref, acc) do
    receive do
      {event, ^ref, _measurements, metadata} -> collect(ref, [{event, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
