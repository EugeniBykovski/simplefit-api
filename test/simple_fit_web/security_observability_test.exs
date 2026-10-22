defmodule SimpleFitWeb.SecurityObservabilityTest do
  @moduledoc """
  Identity security observability over HTTP and PostgreSQL (SF-29, ADR 0019):

    * every authentication and personal-data endpoint, sent malformed bodies
      carrying planted canaries, answers without a server error and leaks the
      canaries into no log (debug level), response, Sentry event or SimpleFit
      telemetry metadata;
    * expected failures (401, 403, 429) are measured but never become Sentry
      events; a refresh-token reuse is measured and logged as a warning
      without the token.
  """

  # Not async: global log level, telemetry handlers and Sentry collection.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts

  @marker "CANARYsf29obs4Kq8Zt2Mw6Vn0Rx3Ly7Hb1Pd5"
  @origin "http://localhost:3000"

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    Sentry.Test.start_collecting_sentry_reports()
    on_exit(fn -> Logger.configure(level: level) end)

    {:ok, user} = Accounts.register_user(:email, "observability@example.com")
    {:ok, credentials} = Accounts.create_session(user)
    %{credentials: credentials}
  end

  # Collects every [:simple_fit, ...] event this process emits.
  defp collect_telemetry(fun) do
    parent = self()
    id = {__MODULE__, make_ref()}

    events = [
      [:simple_fit, :auth, :email, :requested],
      [:simple_fit, :auth, :email, :sent],
      [:simple_fit, :auth, :email, :verified],
      [:simple_fit, :auth, :email, :rejected],
      [:simple_fit, :auth, :email, :rate_limited],
      [:simple_fit, :auth, :google, :rejected],
      [:simple_fit, :auth, :google, :unavailable],
      [:simple_fit, :auth, :google, :rate_limited],
      [:simple_fit, :auth, :apple, :rejected],
      [:simple_fit, :auth, :apple, :unavailable],
      [:simple_fit, :auth, :apple, :rate_limited],
      [:simple_fit, :auth, :session, :refresh],
      [:simple_fit, :coaching, :relationship, :activated],
      [:simple_fit, :coaching, :relationship, :ended],
      [:simple_fit, :coaching, :invitation, :created],
      [:simple_fit, :coaching, :invitation, :resent],
      [:simple_fit, :coaching, :invitation, :cancelled],
      [:simple_fit, :coaching, :invitation, :accepted],
      [:simple_fit, :coaching, :invitation, :declined],
      [:simple_fit, :coaching, :invitation, :rejected],
      [:simple_fit, :coaching, :invitation, :rate_limited],
      [:simple_fit, :coaching, :invitation, :data_rules_acknowledged],
      [:simple_fit, :training, :session, :created],
      [:simple_fit, :training, :session, :updated],
      [:simple_fit, :training, :session, :cancelled],
      [:simple_fit, :training, :session, :completed]
    ]

    :telemetry.attach_many(id, events, &__MODULE__.forward_event/4, parent)

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain([])
  end

  @doc false
  def forward_event(event, measurements, metadata, parent),
    do: send(parent, {:telemetry, event, measurements, metadata})

  defp drain(acc) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp json(conn, method, path, body, bearer \\ nil) do
    conn
    |> put_req_header("content-type", "application/json")
    |> then(&if(bearer, do: put_req_header(&1, "authorization", "Bearer " <> bearer), else: &1))
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  describe "malformed requests with planted canaries" do
    @fields ~w(email code registration_token token refresh_token id_token identity_token nonce
               authorization_code full_name date_of_birth consents product_news intent
               refresh_token_transport display_name brand_name city bio country_code languages
               coaching_formats competition_levels context message disclosure_version
               document_version relationship_id client_request_id title training_type starts_at
               time_zone duration_minutes notes status completed_at view)

    @endpoints [
      {:post, "/api/auth/session/refresh", :anonymous},
      {:post, "/api/auth/logout", :anonymous},
      {:post, "/api/auth/email/registrations", :anonymous},
      {:post, "/api/auth/email/registrations/verify", :anonymous},
      {:post, "/api/auth/email/registrations/status", :anonymous},
      {:post, "/api/auth/email/verification-links/verify", :anonymous},
      {:post, "/api/auth/email/sign-in", :anonymous},
      {:post, "/api/auth/email/sign-in/verify", :anonymous},
      {:post, "/api/auth/google", :anonymous},
      {:post, "/api/auth/apple", :anonymous},
      {:get, "/api/me", :canary_bearer},
      {:patch, "/api/v1/me/account-profile", :signed_in},
      {:post, "/api/v1/me/account-profile/complete-registration", :signed_in},
      {:get, "/api/v1/me/email-identities", :signed_in},
      {:post, "/api/v1/me/email-identities/link-challenge", :signed_in},
      {:post, "/api/v1/me/email-identities/confirm-link", :signed_in},
      {:post, "/api/v1/me/email-identities/confirm-link", :canary_bearer},
      {:patch, "/api/v1/me/fighter-profile", :signed_in},
      {:post, "/api/v1/me/fighter-profile/complete-onboarding", :signed_in},
      {:get, "/api/v1/me/coach-profile", :signed_in},
      {:patch, "/api/v1/me/coach-profile", :signed_in},
      {:post, "/api/v1/me/coach-profile/complete-onboarding", :signed_in},
      {:put, "/api/v1/me/first-run/canary", :signed_in},
      {:get, "/api/v1/me/entry", :signed_in},
      {:put, "/api/v1/me/entry/context", :signed_in},
      {:get, "/api/v1/me/coach/fighters", :signed_in},
      {:get, "/api/v1/me/coach/fighters/sfa_#{@marker}", :signed_in},
      {:post, "/api/v1/me/coach/fighters/sfa_#{@marker}/end", :signed_in},
      {:get, "/api/v1/me/coaches", :signed_in},
      {:post, "/api/v1/me/coaches/#{@marker}/end", :signed_in},
      {:get, "/api/v1/me/coach/data-rules", :signed_in},
      {:post, "/api/v1/me/coach/data-rules/acknowledge", :signed_in},
      {:post, "/api/v1/me/coach/invitations", :signed_in},
      {:get, "/api/v1/me/coach/invitations", :signed_in},
      {:post, "/api/v1/me/coach/invitations/sfi_#{@marker}/resend", :signed_in},
      {:post, "/api/v1/me/coach/invitations/#{@marker}/cancel", :signed_in},
      {:post, "/api/v1/coach-invitations/preview", :anonymous},
      {:post, "/api/v1/me/coach-invitations/accept", :signed_in},
      {:post, "/api/v1/me/coach-invitations/decline", :signed_in},
      {:post, "/api/v1/me/coach/training-sessions", :signed_in},
      {:get, "/api/v1/me/coach/training-sessions?cursor=#{@marker}", :signed_in},
      {:get, "/api/v1/me/coach/training-sessions/#{@marker}", :signed_in},
      {:patch, "/api/v1/me/coach/training-sessions/#{@marker}", :signed_in},
      {:post, "/api/v1/me/coach/training-sessions/#{@marker}/cancel", :signed_in},
      {:get, "/api/v1/me/training-sessions?from=#{@marker}", :signed_in},
      {:get, "/api/v1/me/training-sessions/#{@marker}", :signed_in},
      {:get, "/api/v1/me/training-sessions?view=#{@marker}", :signed_in},
      {:post, "/api/v1/me/training-sessions/#{@marker}/complete", :signed_in}
    ]

    defp shapes do
      [
        "sfr_#{@marker}abcdefghij",
        "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ#{@marker}.c2ln",
        "#{String.downcase(@marker)}@example.com",
        "Full #{@marker} Name",
        12_345,
        nil,
        ["sfa_#{@marker}"],
        %{"nested" => "sfg_#{@marker}"},
        String.duplicate("A", 20_000) <> @marker
      ]
    end

    test "never fail with 5xx and leak no canary into logs, bodies, Sentry or telemetry", %{
      credentials: c
    } do
      {conns, log, telemetry} =
        then(nil, fn _ ->
          ref = make_ref()

          telemetry =
            collect_telemetry(fn ->
              log =
                capture_log([level: :debug], fn ->
                  conns =
                    for {method, path, auth} <- @endpoints, shape <- shapes() do
                      body = Map.new(@fields, &{&1, shape})

                      bearer =
                        case auth do
                          :anonymous -> nil
                          :canary_bearer -> "sfa_#{@marker}"
                          :signed_in -> c.access_token
                        end

                      {path, json(build_conn(), method, path, body, bearer)}
                    end

                  send(self(), {ref, conns})
                end)

              send(self(), {ref, :log, log})
            end)

          assert_received {^ref, conns}
          assert_received {^ref, :log, log}
          {conns, log, telemetry}
        end)

      for {path, conn} <- conns do
        # Never a server error. Designed non-4xx answers stay as designed:
        # logout is an idempotent 204 (ADR 0010), a code request for a
        # well-formed address is a 202 whoever owns it and an unknown
        # registration token reads as "expired" (enumeration-safe, ADR 0012).
        assert conn.status < 500, "#{path} answered #{conn.status}"
        # An error never echoes what was sent. (A success may return the
        # caller's own saved data, e.g. a display name they just set.)
        if conn.status >= 400 do
          refute conn.resp_body =~ @marker, "#{path} echoes a canary in a #{conn.status}"
          refute conn.resp_body =~ String.downcase(@marker)
        end
      end

      refute log =~ @marker
      refute log =~ String.downcase(@marker)
      assert Sentry.Test.pop_sentry_reports() == []

      for {event, _measurements, metadata} <- telemetry do
        refute inspect(metadata, limit: :infinity) =~ @marker, inspect(event)
        refute inspect(metadata, limit: :infinity) =~ String.downcase(@marker)
      end
    end
  end

  describe "classification" do
    test "every refresh is measured by outcome only; a reuse is a warning without the token", %{
      credentials: c
    } do
      {telemetry, log} =
        then(nil, fn _ ->
          ref = make_ref()

          telemetry =
            collect_telemetry(fn ->
              log =
                capture_log([level: :debug], fn ->
                  rotated =
                    json(build_conn(), :post, "/api/auth/session/refresh", %{
                      refresh_token: c.refresh_token
                    })

                  lost = json_response(rotated, 200)

                  # The consumed token again before its successor was used:
                  # a lost-response recovery (SF-75).
                  assert json(build_conn(), :post, "/api/auth/session/refresh", %{
                           refresh_token: c.refresh_token
                         }).status == 200

                  # The superseded successor: reuse, which revokes the session.
                  assert json(build_conn(), :post, "/api/auth/session/refresh", %{
                           refresh_token: lost["refresh_token"]
                         }).status == 401

                  # Malformed and unknown tokens: rejected.
                  assert json(build_conn(), :post, "/api/auth/session/refresh", %{
                           refresh_token: "sfr_#{@marker}"
                         }).status == 401
                end)

              send(self(), {ref, log})
            end)

          assert_received {^ref, log}
          {telemetry, log}
        end)

      outcomes =
        for {[:simple_fit, :auth, :session, :refresh], %{count: 1}, metadata} <- telemetry do
          assert Map.keys(metadata) == [:outcome]
          metadata.outcome
        end

      assert outcomes == [:rotated, :recovered, :reuse, :rejected]
      assert log =~ "refresh token recovery: unused successor superseded"
      assert log =~ "refresh token reuse: session revoked"
      refute log =~ c.refresh_token
      refute log =~ @marker
      # A warning, not an incident: nothing reaches Sentry.
      assert Sentry.Test.pop_sentry_reports() == []
    end

    test "401 and 403 are expected answers, never Sentry events" do
      assert get(build_conn(), "/api/me").status == 401

      forbidden =
        build_conn()
        |> put_req_cookie(SimpleFitWeb.SessionTransport.cookie_name(), "sfr_#{@marker}")
        |> put_req_header("origin", "https://evil.example")
        |> post("/api/auth/session/refresh")

      assert forbidden.status == 403
      assert Sentry.Test.pop_sentry_reports() == []
    end

    test "a 429 is measured and logged by route and status, without the address" do
      email = "limited-#{System.unique_integer([:positive])}@example.com"

      {telemetry, log} =
        then(nil, fn _ ->
          ref = make_ref()

          telemetry =
            collect_telemetry(fn ->
              log =
                capture_log([level: :info], fn ->
                  statuses =
                    for _ <- 1..3 do
                      json(build_conn(), :post, "/api/auth/email/sign-in", %{email: email}).status
                    end

                  # The per-address minute window allows one request.
                  assert statuses == [202, 429, 429]
                end)

              send(self(), {ref, log})
            end)

          assert_received {^ref, log}
          {telemetry, log}
        end)

      limited =
        for {[:simple_fit, :auth, :email, :rate_limited], _, metadata} <- telemetry, do: metadata

      assert length(limited) == 2
      assert Enum.all?(limited, &(&1 == %{}))
      assert log =~ "status=429"
      assert log =~ "route=/api/auth/email/sign-in"
      refute log =~ email
      assert Sentry.Test.pop_sentry_reports() == []
      reset_rate_limits()
    end

    test "the browser transport's CSRF boundary holds: exact origins only" do
      for origin <- [
            "https://evil.example",
            "http://localhost:3000.evil.example",
            "http://evil.localhost:3000",
            "null"
          ] do
        conn =
          build_conn()
          |> put_req_cookie(SimpleFitWeb.SessionTransport.cookie_name(), "sfr_#{@marker}")
          |> put_req_header("origin", origin)
          |> put_req_header("x-simplefit-csrf", "1")
          |> post("/api/auth/session/refresh")

        assert conn.status == 403, origin
      end

      # The allowed origin still needs the CSRF header.
      missing_header =
        build_conn()
        |> put_req_cookie(SimpleFitWeb.SessionTransport.cookie_name(), "sfr_#{@marker}")
        |> put_req_header("origin", @origin)
        |> post("/api/auth/session/refresh")

      assert missing_header.status == 403
    end
  end
end
