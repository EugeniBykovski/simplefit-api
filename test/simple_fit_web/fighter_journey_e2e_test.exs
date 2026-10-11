defmodule SimpleFitWeb.FighterJourneyE2ETest do
  @moduledoc """
  The whole new-Fighter journey over HTTP on the real endpoints and
  PostgreSQL (SF-30, the SF-18 acceptance gate): Identity → Auth → Account
  Registration (SF-44) → Fighter onboarding (SF-25) → FirstRun → Fighter
  Home, by one user on two clients at once:

    * "mobile": email registration, refresh token in the body;
    * "web": email sign-in on another device, refresh token in the
      HttpOnly cookie with the CSRF proof.

  Each step is resumed or continued from the other client, every response
  is checked against the OpenAPI schema, and the database is checked to hold
  exactly one of everything the journey creates.
  """

  # Not async: rate limits and queued emails are shared by the flow.
  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts.{AccountConsent, AccountProfile, Identity, Session, User}
  alias SimpleFit.Fighters.FighterProfile
  alias SimpleFit.FirstRun.Outcome
  alias SimpleFit.Repo
  alias SimpleFitWeb.{ApiSpec, SessionTransport}

  @origin "http://localhost:3000"
  @email "journey-fighter@example.com"

  # --- Clients --------------------------------------------------------------

  defp web(conn) do
    conn
    |> put_req_header("origin", @origin)
    |> put_req_header("x-simplefit-csrf", "1")
  end

  defp send_json(conn, method, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, body && Jason.encode!(body))
  end

  defp api(token, method, path, body \\ nil) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> send_json(method, path, body)
  end

  defp ok(conn, schema) do
    body = json_response(conn, 200)
    assert_schema(body, schema, ApiSpec.spec())
    body
  end

  defp field_codes(conn) do
    body = json_response(conn, 422)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    body["error"]["details"]["field_codes"]
  end

  # Mobile: email registration (E01 code), body transport.
  defp register_on_mobile(email) do
    started =
      build_conn()
      |> send_json(:post, ~p"/api/auth/email/registrations", %{email: email})
      |> json_response(202)

    tokens =
      build_conn()
      |> send_json(:post, ~p"/api/auth/email/registrations/verify", %{
        registration_token: started["registration_token"],
        code: code_from(last_email_to(email))
      })
      |> ok("SessionTokens")

    assert %{"refresh_token_transport" => "body", "refresh_token" => "sfr_" <> _} = tokens
    reset_rate_limits()
    tokens
  end

  # Web: email sign-in (E17 code), cookie transport. Returns the access
  # token and the refresh cookie the browser would keep.
  defp sign_in_on_web(email) do
    build_conn()
    |> send_json(:post, ~p"/api/auth/email/sign-in", %{email: email})
    |> json_response(202)

    conn =
      build_conn()
      |> web()
      |> send_json(:post, ~p"/api/auth/email/sign-in/verify", %{
        email: email,
        code: code_from(last_email_to(email)),
        refresh_token_transport: "cookie"
      })

    body = ok(conn, "SessionTokens")
    assert %{"refresh_token_transport" => "cookie"} = body
    refute Map.has_key?(body, "refresh_token")
    reset_rate_limits()
    {body["access_token"], refresh_cookie(conn)}
  end

  defp refresh_cookie(conn) do
    assert %{value: "sfr_" <> _ = value, http_only: true} =
             conn.resp_cookies[SessionTransport.cookie_name()]

    value
  end

  # The web client's silent refresh: a new access token and rotated cookie.
  defp refresh_on_web(cookie) do
    conn =
      build_conn()
      |> web()
      |> put_req_cookie(SessionTransport.cookie_name(), cookie)
      |> post(~p"/api/auth/session/refresh")

    body = ok(conn, "SessionTokens")
    rotated = refresh_cookie(conn)
    refute rotated == cookie
    {body["access_token"], rotated}
  end

  defp entry(token, query),
    do:
      token
      |> api(:get, "/api/v1/me/entry" <> query)
      |> ok("EntryResponse")
      |> Map.fetch!("entry")

  defp account_profile(token, method, path, body \\ nil),
    do:
      token
      |> api(method, path, body)
      |> ok("AccountProfileResponse")
      |> Map.fetch!("account_profile")

  defp fighter_profile(token, method, path, body \\ nil),
    do:
      token
      |> api(method, path, body)
      |> ok("FighterProfileResponse")
      |> Map.fetch!("fighter_profile")

  defp first_run(token) do
    %{"experiences" => experiences} =
      token |> api(:get, "/api/v1/me/first-run") |> ok("FirstRunResponse")

    Map.new(experiences, &{&1["experience"], &1["status"]})
  end

  defp record_first_run(token, experience, outcome) do
    token
    |> api(:put, "/api/v1/me/first-run/#{experience}", %{outcome: outcome})
    |> ok("FirstRunExperienceResponse")
    |> get_in(["experience", "status"])
  end

  defp dob(years_ago), do: Date.utc_today() |> Date.shift(year: -years_ago) |> Date.to_iso8601()

  defp count(schema, user_id),
    do: Repo.aggregate(from(r in schema, where: r.user_id == ^user_id), :count)

  # --- The journey ----------------------------------------------------------

  test "a new Fighter on mobile and web: registration, onboarding, first run, home" do
    # 1. Mobile: a new email identity and the first session.
    mobile_tokens = register_on_mobile(@email)
    mobile = mobile_tokens["access_token"]

    %{"user" => %{"id" => user_id}} = mobile |> api(:get, ~p"/api/me") |> json_response(200)

    # 2. Mobile entry with the Fighter intent: shared registration comes first.
    assert %{"destination" => "account_registration", "intent" => "fighter"} =
             entry(mobile, "?intent=fighter")

    # 3. Mobile saves part of the account registration, then stops.
    partial =
      account_profile(mobile, :patch, "/api/v1/me/account-profile", %{
        full_name: "Alex Kowalski",
        date_of_birth: dob(30)
      })

    assert partial["registration"]["status"] == "in_progress"
    assert partial["registration"]["missing_requirements"] == ["terms", "privacy"]

    # 4. Web: the same person signs in on another device, the same user.
    {web, cookie} = sign_in_on_web(@email)
    assert %{"user" => %{"id" => ^user_id}} = web |> api(:get, ~p"/api/me") |> json_response(200)

    # 5. Web resumes the registration where mobile left it.
    resumed = account_profile(web, :get, "/api/v1/me/account-profile")
    assert resumed["full_name"] == "Alex Kowalski"
    assert resumed["registration"]["status"] == "in_progress"

    # Completing before the consents fails with exactly what is missing.
    assert web |> api(:post, "/api/v1/me/account-profile/complete-registration") |> field_codes() ==
             %{"terms" => ["required"], "privacy" => ["required"]}

    account_profile(web, :patch, "/api/v1/me/account-profile", %{
      accept_terms: true,
      accept_privacy: true
    })

    registered = account_profile(web, :post, "/api/v1/me/account-profile/complete-registration")
    assert registered["registration"]["status"] == "complete"

    # 6. Both clients now enter Fighter onboarding; it is mandatory.
    for token <- [mobile, web] do
      assert %{"destination" => "fighter_onboarding", "mandatory" => true} =
               entry(token, "?intent=fighter")
    end

    # 7. Fighter onboarding, split across clients. The web's access token
    #    expires meanwhile: the silent cookie refresh keeps the journey going.
    basics =
      fighter_profile(mobile, :patch, "/api/v1/me/fighter-profile", %{
        display_name: "Alex K.",
        username: "journey_alex",
        country_code: "PL",
        city: "Warsaw"
      })

    assert basics["onboarding"]["status"] == "in_progress"

    {web, cookie} = refresh_on_web(cookie)

    experience =
      fighter_profile(web, :patch, "/api/v1/me/fighter-profile", %{
        experience_level: "competitive_amateur",
        stance: "orthodox",
        amateur_bout_count: 14,
        goals: ["improve_technique", "competition"]
      })

    # Partial saves from different clients never erase each other.
    assert %{
             "display_name" => "Alex K.",
             "username" => "journey_alex",
             "city" => "Warsaw",
             "stance" => "orthodox",
             "amateur_bout_count" => 14
           } = experience

    assert experience["onboarding"]["missing_requirements"] == []

    # Mobile completes; a repeat from web is idempotent.
    completed =
      fighter_profile(mobile, :post, "/api/v1/me/fighter-profile/complete-onboarding")

    assert completed["onboarding"]["status"] == "completed"

    again = fighter_profile(web, :post, "/api/v1/me/fighter-profile/complete-onboarding")
    assert again["onboarding"]["completed_at"] == completed["onboarding"]["completed_at"]

    # 8. Both clients now resolve to Fighter Home, with or without an intent.
    for token <- [mobile, web], query <- ["", "?intent=fighter"] do
      assert %{
               "destination" => "fighter_home",
               "mandatory" => false,
               "capabilities" => ["FIGHTER"]
             } = entry(token, query)
    end

    # 9. First run: each client's experience is its own.
    pending = %{"fighter_web_tour" => "pending", "fighter_mobile_first_run" => "pending"}
    assert first_run(web) == pending
    assert record_first_run(web, "fighter_web_tour", "completed") == "completed"
    assert first_run(mobile) == %{pending | "fighter_web_tour" => "completed"}

    assert record_first_run(mobile, "fighter_mobile_first_run", "dismissed") == "dismissed"
    # The first outcome wins, from either client.
    assert record_first_run(web, "fighter_mobile_first_run", "completed") == "dismissed"

    assert first_run(web) == %{
             "fighter_web_tour" => "completed",
             "fighter_mobile_first_run" => "dismissed"
           }

    # 10. Web logs out; mobile is untouched.
    assert build_conn()
           |> web()
           |> put_req_cookie(SessionTransport.cookie_name(), cookie)
           |> put_req_header("authorization", "Bearer " <> web)
           |> post(~p"/api/auth/logout")
           |> response(204)

    assert web |> api(:get, ~p"/api/me") |> json_response(401)
    assert mobile |> api(:get, ~p"/api/me") |> json_response(200)

    # 11. Web signs in again: straight home, nothing is created twice.
    {web, _cookie} = sign_in_on_web(@email)
    assert %{"destination" => "fighter_home"} = entry(web, "?intent=fighter")
    assert first_run(web)["fighter_web_tour"] == "completed"

    # Registration again for the same address does not create a second user.
    build_conn()
    |> send_json(:post, ~p"/api/auth/email/registrations", %{email: @email})
    |> json_response(202)

    reset_rate_limits()

    # 12. The database holds exactly one of everything.
    assert Repo.aggregate(User, :count) == 1
    assert count(Identity, user_id) == 1
    assert Repo.one!(from(i in Identity, select: i.provider)) == :email
    assert count(AccountProfile, user_id) == 1
    assert count(FighterProfile, user_id) == 1

    assert Repo.all(from(c in AccountConsent, where: c.user_id == ^user_id, select: c.kind))
           |> Enum.sort() == [:privacy, :terms]

    assert Repo.all(
             from(o in Outcome,
               where: o.user_id == ^user_id,
               select: {o.experience, o.outcome},
               order_by: o.experience
             )
           ) ==
             [fighter_web_tour: :completed, fighter_mobile_first_run: :dismissed]
             |> Enum.sort()

    # Three sign-ins (mobile, web, web again); the logged-out one is revoked.
    sessions = Repo.all(from(s in Session, where: s.user_id == ^user_id))
    assert length(sessions) == 3
    assert Enum.count(sessions, &is_nil(&1.revoked_at)) == 2
  end
end
