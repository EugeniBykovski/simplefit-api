defmodule SimpleFitWeb.CoachInvitationControllerTest do
  @moduledoc """
  Coach invitations over HTTP on the real endpoints and PostgreSQL (SF-57):
  the backend scenarios A-J, OpenAPI schemas, authorization and privacy. A
  new recipient registers through the real email authentication endpoints
  and completes account registration and fighter onboarding over HTTP.
  """

  # Not async: sharing configuration, queued emails and rate limits are shared.
  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaching.{Invitation, Relationship}
  alias SimpleFitWeb.ApiSpec

  @canary "CANARYsf57inv3Hp8Lq2Wz6"

  setup do
    configure_sharing()
    reset_rate_limits()
    :ok
  end

  # --- Clients -------------------------------------------------------------

  defp send_json(conn, method, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, body && Jason.encode!(body))
  end

  defp token_for(%User{} = user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp api(who, method, path, body \\ nil)

  defp api(%User{} = user, method, path, body), do: api(token_for(user), method, path, body)

  defp api(token, method, path, body) when is_binary(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> send_json(method, path, body)
  end

  defp anonymous(method, path, body), do: send_json(build_conn(), method, path, body)

  defp body(conn, status, schema) do
    body = json_response(conn, status)
    assert_schema(body, schema, ApiSpec.spec())
    body
  end

  defp error(conn, status, code) do
    body = json_response(conn, status)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    assert body["error"]["code"] == code
    body["error"]
  end

  defp invite(coach, email, extra \\ %{}),
    do: api(coach, :post, "/api/v1/me/coach/invitations", Map.put(extra, "email", email))

  defp preview(token), do: anonymous(:post, "/api/v1/coach-invitations/preview", %{token: token})

  defp accept(who, token, version \\ version()),
    do:
      api(who, :post, "/api/v1/me/coach-invitations/accept", %{
        token: token,
        disclosure_version: version,
        document_language: "en"
      })

  defp decline(who, token),
    do: api(who, :post, "/api/v1/me/coach-invitations/decline", %{token: token})

  defp relationships, do: Repo.aggregate(Relationship, :count)
  defp address, do: "recipient-#{System.unique_integer([:positive])}@example.com"

  # Registration over HTTP: E01 code, body transport. Returns the access token.
  defp register(email) do
    started =
      anonymous(:post, "/api/auth/email/registrations", %{email: email}) |> json_response(202)

    tokens =
      anonymous(:post, "/api/auth/email/registrations/verify", %{
        registration_token: started["registration_token"],
        code: code_from(last_email_to(email))
      })
      |> body(200, "SessionTokens")

    reset_rate_limits()
    tokens["access_token"]
  end

  defp onboard(token) do
    body(
      api(token, :patch, "/api/v1/me/account-profile", %{
        full_name: "Alex Kowalski",
        date_of_birth: "1995-04-02",
        accept_terms: true,
        accept_privacy: true
      }),
      200,
      "AccountProfileResponse"
    )

    body(
      api(token, :post, "/api/v1/me/account-profile/complete-registration"),
      200,
      "AccountProfileResponse"
    )

    body(
      api(token, :patch, "/api/v1/me/fighter-profile", %{
        display_name: "Alex K.",
        username: "alex_#{System.unique_integer([:positive])}",
        country_code: "PL",
        city: "Warsaw",
        experience_level: "amateur",
        stance: "orthodox"
      }),
      200,
      "FighterProfileResponse"
    )

    body(
      api(token, :post, "/api/v1/me/fighter-profile/complete-onboarding"),
      200,
      "FighterProfileResponse"
    )
  end

  # --- Scenarios -------------------------------------------------------------

  test "A. a new recipient registers, onboards and accepts explicitly" do
    coach = inviting_coach!()
    email = address()
    users = Repo.aggregate(User, :count)

    created = invite(coach, email) |> body(201, "CoachInvitationResponse")
    assert created["invitation"]["status"] == "pending"
    assert Repo.aggregate(User, :count) == users
    token = last_token_to(email)

    # Signed out: the link shows the coach and the disclosure, nothing else.
    shown = preview(token) |> body(200, "CoachInvitationPreview")
    assert shown["invitation"]["coach"]["display_name"] == "Coach Marek"
    assert shown["disclosure"]["version"] == version()
    refute Jason.encode!(shown) =~ email

    access = register(email)

    # Not yet a fighter: the recipient is sent through onboarding first.
    assert %{"details" => %{"field_codes" => %{"account_registration" => ["required"]}}} =
             accept(access, token) |> error(422, "validation_error")

    onboard(access)
    assert relationships() == 0

    accepted = accept(access, token) |> body(200, "CoachInvitationAcceptResponse")
    assert accepted["outcome"] == "created"

    mine = api(access, :get, "/api/v1/me/coaches") |> body(200, "MyCoachRelationshipList")
    assert [%{"relationship_id" => id, "status" => "active"}] = mine["relationships"]
    assert id == accepted["relationship_id"]

    # A token works once; no duplicate.
    error(accept(access, token), 410, "invitation_unavailable")
    assert relationships() == 1

    listed = api(coach, :get, "/api/v1/me/coach/invitations") |> body(200, "CoachInvitationList")
    assert [%{"status" => "accepted"}] = listed["invitations"]
  end

  test "B. an existing fighter is never connected until they accept" do
    coach = inviting_coach!()
    email = address()
    fighter = email_fighter!(email)

    invite(coach, email) |> body(201, "CoachInvitationResponse")
    assert relationships() == 0

    accept(fighter, last_token_to(email)) |> body(200, "CoachInvitationAcceptResponse")
    assert relationships() == 1
  end

  test "C. a forwarded link is useless to anyone else" do
    coach = inviting_coach!()
    email = address()
    invite(coach, email)
    token = last_token_to(email)
    other = email_fighter!(address())

    error(accept(other, token), 403, "invitation_recipient_mismatch")
    error(decline(other, token), 403, "invitation_recipient_mismatch")
    assert relationships() == 0
  end

  test "D. declining creates nothing and ends the link" do
    email = address()
    invite(inviting_coach!(), email)
    token = last_token_to(email)
    fighter = email_fighter!(email)

    assert response(decline(fighter, token), 204) == ""
    error(accept(fighter, token), 410, "invitation_unavailable")
    error(preview(token), 410, "invitation_unavailable")
    assert relationships() == 0
  end

  test "E. a cancelled invitation cannot be accepted" do
    coach = inviting_coach!()
    email = address()
    id = (invite(coach, email) |> json_response(201))["invitation"]["invitation_id"]
    token = last_token_to(email)

    assert response(api(coach, :post, "/api/v1/me/coach/invitations/#{id}/cancel"), 204) == ""
    error(accept(email_fighter!(email), token), 410, "invitation_unavailable")
    assert relationships() == 0
  end

  test "F. an expired invitation cannot be accepted, and its token never works again" do
    email = address()
    invite(inviting_coach!(), email)
    token = last_token_to(email)
    fighter = email_fighter!(email)

    Repo.update_all(Invitation, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])

    error(accept(fighter, token), 410, "invitation_unavailable")
    error(preview(token), 410, "invitation_unavailable")
    assert relationships() == 0
  end

  test "G. two acceptances at once: one relationship" do
    email = address()
    invite(inviting_coach!(), email)
    token = last_token_to(email)
    access = token_for(email_fighter!(email))

    statuses =
      [fn -> accept(access, token).status end, fn -> accept(access, token).status end]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(10_000)
      |> Enum.sort()

    assert statuses == [200, 410]
    assert relationships() == 1
  end

  test "H. a resend rotates the link under its limits" do
    coach = inviting_coach!()
    email = address()
    id = (invite(coach, email) |> json_response(201))["invitation"]["invitation_id"]
    old = last_token_to(email)

    conn = api(coach, :post, "/api/v1/me/coach/invitations/#{id}/resend")
    error(conn, 429, "rate_limited")
    assert [_] = get_resp_header(conn, "retry-after")

    Repo.update_all(Invitation, set: [last_sent_at: DateTime.add(DateTime.utc_now(), -61)])

    resent =
      api(coach, :post, "/api/v1/me/coach/invitations/#{id}/resend")
      |> body(200, "CoachInvitationResponse")

    assert resent["invitation"]["resends_remaining"] == 2
    new = last_token_to(email)
    fighter = email_fighter!(email)

    error(accept(fighter, old), 410, "invitation_unavailable")
    accept(fighter, new) |> body(200, "CoachInvitationAcceptResponse")
    assert relationships() == 1
  end

  test "I. with the gate off nothing grants sharing; cancel, decline and ending still work" do
    coach = inviting_coach!()
    email = address()
    id = (invite(coach, email) |> json_response(201))["invitation"]["invitation_id"]
    token = last_token_to(email)
    fighter = email_fighter!(email)
    jobs = Repo.aggregate(Oban.Job, :count)

    set_sharing(enabled: false)

    error(invite(coach, address()), 404, "not_found")
    error(preview(token), 404, "not_found")
    error(accept(fighter, token), 404, "not_found")
    error(api(coach, :get, "/api/v1/me/coach/invitations"), 404, "not_found")
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert Repo.one!(from(i in Invitation, select: i.accepted_disclosure_version)) == nil

    assert response(api(coach, :post, "/api/v1/me/coach/invitations/#{id}/cancel"), 204) == ""

    # No configured legal versions at all: the same.
    set_sharing(disclosures: %{}, current: nil, data_rules: nil)
    error(invite(coach, address()), 404, "not_found")
    assert relationships() == 0
  end

  test "J. accounts stay isolated: invitations, acceptance and self-coaching" do
    coach_a = inviting_coach!("Coach A")
    coach_b = inviting_coach!("Coach B")
    email = address()
    id_a = (invite(coach_a, email) |> json_response(201))["invitation"]["invitation_id"]

    # Each coach sees only their own invitations, and cannot act on others'.
    assert %{"invitations" => []} =
             api(coach_b, :get, "/api/v1/me/coach/invitations")
             |> body(200, "CoachInvitationList")

    error(api(coach_b, :post, "/api/v1/me/coach/invitations/#{id_a}/cancel"), 404, "not_found")
    error(api(coach_b, :post, "/api/v1/me/coach/invitations/#{id_a}/resend"), 404, "not_found")

    # A user holding both profiles cannot invite their own address.
    {:ok, both} = Accounts.register_user(:email, "both-#{System.unique_integer()}@example.com")

    both =
      both
      |> SimpleFit.FighterOnboardingHelpers.complete_fighter_onboarding!()
      |> complete_coach!()

    api(both, :post, "/api/v1/me/coach/data-rules/acknowledge", %{
      document_version: data_rules_version(),
      document_language: "en"
    })
    |> body(200, "CoachDataRulesResponse")

    [own] = Accounts.verified_email_addresses(both)

    assert %{"details" => %{"field_codes" => %{"email" => ["invalid"]}}} =
             invite(both, own) |> error(422, "validation_error")

    assert relationships() == 0
  end

  # --- Contract and privacy ----------------------------------------------------

  test "the data rules: read, acknowledge, stale" do
    coach = coach_user!()

    assert %{"data_rules" => %{"document_version" => v, "acknowledged_at" => nil}} =
             api(coach, :get, "/api/v1/me/coach/data-rules")
             |> body(200, "CoachDataRulesResponse")

    assert %{"details" => %{"document_version" => "stale"}} =
             api(coach, :post, "/api/v1/me/coach/data-rules/acknowledge", %{
               document_version: "v0",
               document_language: "en"
             })
             |> error(409, "conflict")

    error(invite(coach, address()), 409, "conflict")

    api(coach, :post, "/api/v1/me/coach/data-rules/acknowledge", %{
      document_version: v,
      document_language: "en"
    })
    |> body(200, "CoachDataRulesResponse")

    invite(coach, address()) |> body(201, "CoachInvitationResponse")
  end

  test "authentication is required everywhere but the preview" do
    id = Ecto.UUID.generate()

    for {method, path} <- [
          {:get, "/api/v1/me/coach/data-rules"},
          {:post, "/api/v1/me/coach/data-rules/acknowledge"},
          {:post, "/api/v1/me/coach/invitations"},
          {:get, "/api/v1/me/coach/invitations"},
          {:post, "/api/v1/me/coach/invitations/#{id}/resend"},
          {:post, "/api/v1/me/coach/invitations/#{id}/cancel"},
          {:post, "/api/v1/me/coach-invitations/accept"},
          {:post, "/api/v1/me/coach-invitations/decline"}
        ] do
      error(anonymous(method, path, %{}), 401, "unauthorized")
    end
  end

  test "no response ever carries a token, digest, sealed address or account data" do
    coach = inviting_coach!()
    email = "#{String.downcase(@canary)}@example.com"
    id = (invite(coach, email) |> json_response(201))["invitation"]["invitation_id"]
    token = last_token_to(email)
    row = Repo.get!(Invitation, id)

    bodies = [
      api(coach, :get, "/api/v1/me/coach/invitations").resp_body,
      preview(token).resp_body,
      accept(email_fighter!(address()), token).resp_body,
      api(coach, :post, "/api/v1/me/coach/invitations/#{id}/cancel", %{}).resp_body
    ]

    for raw <- bodies do
      refute raw =~ token
      refute raw =~ String.downcase(@canary)
      refute raw =~ Base.encode64(row.token_hash)
      refute raw =~ row.recipient_sealed
      refute raw =~ "token_hash"
      refute raw =~ "recipient_digest"
    end

    assert api(coach, :get, "/api/v1/me/coach/invitations").resp_body =~ "c•••@example.com"
  end

  test "with sharing on, malformed bodies with canaries never 5xx, echo or log", %{} do
    coach = inviting_coach!()
    fighter = email_fighter!(address())
    {_invitation, real} = invite!(coach, address())
    coach_token = token_for(coach)
    fighter_token = token_for(fighter)

    shapes = [
      "sfi_#{@canary}abcdefghijklmnopqrstuvwxyz0",
      "#{String.downcase(@canary)}@example.com",
      "Note #{@canary}",
      12_345,
      nil,
      ["sfi_#{@canary}"],
      %{"nested" => "sfi_#{@canary}"},
      String.duplicate("A", 20_000) <> @canary,
      real <> @canary
    ]

    fields = ~w(email message token disclosure_version document_version coach_profile_id status)

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      capture_log([level: :debug], fn ->
        for shape <- shapes,
            {method, path, who} <- [
              {:post, "/api/v1/me/coach/invitations", coach_token},
              {:post, "/api/v1/me/coach/data-rules/acknowledge", coach_token},
              {:post, "/api/v1/coach-invitations/preview", nil},
              {:post, "/api/v1/me/coach-invitations/accept", fighter_token},
              {:post, "/api/v1/me/coach-invitations/decline", fighter_token}
            ] do
          reset_rate_limits()
          body = Map.new(fields, &{&1, shape})
          conn = if who, do: api(who, method, path, body), else: anonymous(method, path, body)

          assert conn.status < 500, "#{path} answered #{conn.status}"

          if conn.status >= 400 do
            refute conn.resp_body =~ @canary, "#{path} echoes a canary"
            refute conn.resp_body =~ String.downcase(@canary)
          end
        end
      end)

    refute log =~ @canary
    refute log =~ String.downcase(@canary)
    refute log =~ real
    assert relationships() == 0
  end

  test "the preview and the responses are rate limited per client" do
    for _ <- 1..30, do: preview("sfi_" <> String.duplicate("A", 43))
    conn = preview("sfi_" <> String.duplicate("A", 43))
    error(conn, 429, "rate_limited")
  end
end
