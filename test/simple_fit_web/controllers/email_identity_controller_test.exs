defmodule SimpleFitWeb.EmailIdentityControllerTest do
  @moduledoc """
  Verified email identity linking over HTTP on the real endpoint and
  PostgreSQL (SF-77, ADR 0024): the contract (OpenAPI schemas, no-store,
  normalized errors, enumeration-safe answers), and the journeys from a
  Google or Apple sign-in to a coach invitation addressed to the linked
  address, with every SF-57/SF-73 gate still in force.
  """

  # Not async: sharing configuration, provider key caches, queued emails and
  # rate limits are shared.
  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.{Accounts, AppleTokens, GoogleTokens, Repo}
  alias SimpleFit.Accounts.{Identity, User}
  alias SimpleFit.Coaching.{Invitation, Relationship}
  alias SimpleFitWeb.ApiSpec

  @list "/api/v1/me/email-identities"
  @request "/api/v1/me/email-identities/link-challenge"
  @confirm "/api/v1/me/email-identities/confirm-link"

  setup do
    configure_sharing()
    reset_rate_limits()
    GoogleTokens.reset()
    GoogleTokens.stub_jwks(self())
    AppleTokens.reset()
    AppleTokens.stub_jwks(self())
    :ok
  end

  defp address, do: "link-http-#{System.unique_integer([:positive])}@example.com"

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp request_link(token, email), do: token |> authed() |> post_json(@request, %{email: email})

  defp confirm_link(token, email, code),
    do: token |> authed() |> post_json(@confirm, %{email: email, code: code})

  defp list(token), do: token |> authed() |> get(@list)

  defp wrong(code),
    do:
      code
      |> String.to_integer()
      |> Kernel.+(1)
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

  # Signs in through the real Google endpoint. The token reports `claim`
  # as a verified email: SimpleFit must ignore it.
  defp google_sign_in(subject, claim) do
    token = GoogleTokens.valid_token(subject, %{"email" => claim, "email_verified" => true})
    body = build_conn() |> post_json("/api/auth/google", %{id_token: token}) |> json_response(200)
    body["access_token"]
  end

  defp apple_sign_in(subject, claim) do
    credential = AppleTokens.credential(subject, %{"email" => claim, "email_verified" => "true"})
    body = build_conn() |> post_json("/api/auth/apple", credential) |> json_response(200)
    body["access_token"]
  end

  defp user_of(token) do
    {:ok, %{user: user}} = Accounts.authenticate_access_token(token)
    user
  end

  defp schema!(conn, status, schema) do
    body = json_response(conn, status)
    assert_schema(body, schema, ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body
  end

  defp error(conn, status, code) do
    body = schema!(conn, status, "ErrorResponse")
    assert body["error"]["code"] == code
    body["error"]
  end

  # Requests a code over HTTP and reads it from the queued email.
  defp link!(token, email) do
    reset_rate_limits()
    assert schema!(request_link(token, email), 202, "EmailIdentityLinkAccepted")
    code = code_from(last_email_to(email))
    schema!(confirm_link(token, email, code), 200, "EmailIdentityLinkResult")
  end

  defp inbox(token), do: token |> authed() |> get("/api/v1/me/coach-invitations")

  defp invite_to!(coach, email) do
    reset_rate_limits()
    invite!(coach, email)
  end

  defp accept_by_id(token, id) do
    token
    |> authed()
    |> post_json("/api/v1/me/coach-invitations/#{id}/accept", %{
      disclosure_version: version(),
      document_language: "en"
    })
  end

  describe "contract" do
    test "every operation requires a valid access token" do
      for conn <- [
            build_conn() |> get(@list),
            build_conn() |> post_json(@request, %{email: address()}),
            build_conn() |> post_json(@confirm, %{email: address(), code: "123456"}),
            authed("sfa_not-a-token") |> post_json(@request, %{email: address()})
          ] do
        error(conn, 401, "unauthorized")
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      end

      assert queued_emails() == []
    end

    test "the request answers the same for a new, an own and another user's address" do
      {:ok, owner} = Accounts.register_user(:email, taken = address())
      {:ok, member} = Accounts.register_user(:email, own = address())
      {:ok, %{access_token: token}} = Accounts.create_session(member)
      before = Repo.aggregate(Identity, :count)

      answers =
        for email <- [address(), own, taken] do
          reset_rate_limits()
          conn = request_link(token, email)
          {conn.status, conn.resp_body}
        end

      assert [{202, body}, {202, body}, {202, body}] = answers
      assert Jason.decode!(body) == %{"expires_in_seconds" => 600, "resend_after_seconds" => 60}
      refute body =~ taken
      refute body =~ owner.id
      assert Repo.aggregate(Identity, :count) == before
    end

    test "D: another user's address is a generic conflict after mailbox proof, and nothing moves" do
      {:ok, owner} = Accounts.register_user(:email, taken = address())
      token = google_sign_in("conflict-#{System.unique_integer([:positive])}", "x@example.com")
      reset_rate_limits()
      assert request_link(token, taken).status == 202
      code = code_from(last_email_to(taken))

      error(confirm_link(token, taken, wrong(code)), 422, "code_invalid")
      conn = confirm_link(token, taken, code)
      body = error(conn, 409, "conflict")

      refute conn.resp_body =~ taken
      refute conn.resp_body =~ owner.id
      assert body["details"] in [nil, %{}]
      assert Accounts.verified_email_addresses(owner) == [taken]
      assert Accounts.verified_email_addresses(user_of(token)) == []
      assert schema!(list(token), 200, "EmailIdentityList") == %{"email_identities" => []}
    end

    test "codes: wrong, replayed and malformed input use the normalized errors without echo" do
      token = google_sign_in("codes-#{System.unique_integer([:positive])}", "x@example.com")
      email = address()
      reset_rate_limits()
      assert request_link(token, email).status == 202
      code = code_from(last_email_to(email))
      error(confirm_link(token, email, wrong(code)), 422, "code_invalid")

      assert schema!(confirm_link(token, email, code), 200, "EmailIdentityLinkResult")["outcome"] ==
               "linked"

      error(confirm_link(token, email, code), 422, "code_expired")

      canary = "CANARYsf77link5Ty8Ui"

      for {path, body} <- [
            {@request, %{email: "#{canary}-not-an-email"}},
            {@request, %{}},
            {@request, %{email: [canary]}},
            {@confirm, %{email: "#{canary}@example.com", code: canary}},
            {@confirm, %{email: email}}
          ] do
        conn = token |> authed() |> post_json(path, body)
        error(conn, 422, "validation_error")
        refute conn.resp_body =~ canary
      end
    end

    test "a user or identity id in the body is ignored: the session decides" do
      {:ok, other} =
        Accounts.register_user(:google, "other-#{System.unique_integer([:positive])}")

      token = google_sign_in("self-#{System.unique_integer([:positive])}", "x@example.com")
      email = address()
      reset_rate_limits()

      assert token
             |> authed()
             |> post_json(@request, %{email: email, user_id: other.id})
             |> Map.get(:status) == 202

      code = code_from(last_email_to(email))

      conn =
        token
        |> authed()
        |> post_json(@confirm, %{
          email: email,
          code: code,
          user_id: other.id,
          identity_id: other.id
        })

      assert schema!(conn, 200, "EmailIdentityLinkResult")["email_identity"]["email"] == email
      assert Accounts.verified_email_addresses(user_of(token)) == [email]
      assert Accounts.verified_email_addresses(other) == []
    end

    test "requests are rate limited with retry-after" do
      token = google_sign_in("limit-#{System.unique_integer([:positive])}", "x@example.com")
      assert request_link(token, address()).status == 202
      conn = request_link(token, address())

      error(conn, 429, "rate_limited")
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..60
    end

    test "J: a code cannot be used after logout (Journey 5)" do
      token = google_sign_in("logout-#{System.unique_integer([:positive])}", "x@example.com")
      email = address()
      reset_rate_limits()
      assert request_link(token, email).status == 202
      code = code_from(last_email_to(email))

      assert token |> authed() |> post("/api/auth/logout") |> Map.get(:status) == 204

      error(confirm_link(token, email, code), 401, "unauthorized")
      assert Repo.aggregate(from(i in Identity, where: i.provider_subject == ^email), :count) == 0
    end

    test "the list shows only the viewer's email identities" do
      {:ok, member} = Accounts.register_user(:email, mine = address())
      {:ok, _} = Accounts.register_user(:email, address())
      {:ok, %{access_token: token}} = Accounts.create_session(member)

      assert %{"email_identities" => [%{"email" => ^mine, "linked_at" => _}]} =
               schema!(list(token), 200, "EmailIdentityList")
    end
  end

  describe "journeys" do
    test "Journey 1 + 6: a Google-only fighter links the invited address; the same user responds" do
      coach = inviting_coach!()
      email = address()
      {invitation, _token} = invite_to!(coach, email)
      subject = "journey-google-#{System.unique_integer([:positive])}"

      # The Google token claims the invited address as verified: it is ignored.
      token = google_sign_in(subject, email)
      user = user_of(token)
      SimpleFit.AccountRegistrationHelpers.complete_account_registration!(user)
      users = Repo.aggregate(User, :count)

      assert %{"invitations" => []} = schema!(inbox(token), 200, "IncomingCoachInvitationList")
      assert schema!(list(token), 200, "EmailIdentityList") == %{"email_identities" => []}

      assert %{"outcome" => "linked", "email_identity" => %{"email" => ^email}} =
               link!(token, email)

      assert [%{"invitation_id" => id, "status" => "pending"}] =
               schema!(inbox(token), 200, "IncomingCoachInvitationList")["invitations"]

      assert id == invitation.id

      # Every acceptance requirement still applies: here the fighter profile.
      details = error(accept_by_id(token, id), 422, "validation_error")["details"]
      assert details["fields"]["fighter_profile"]
      assert Repo.aggregate(Relationship, :count) == 0

      SimpleFit.FighterOnboardingHelpers.complete_fighter_onboarding!(user)
      reset_rate_limits()
      assert json_response(accept_by_id(token, id), 200)["outcome"] == "created"
      assert Repo.get!(Invitation, id).status == :accepted

      # The same user throughout: no second user, and Google sign-in is unchanged.
      assert Repo.aggregate(User, :count) == users
      again = google_sign_in(subject, email)
      assert user_of(again).id == user.id

      assert Repo.all(from(i in Identity, where: i.user_id == ^user.id, select: i.provider))
             |> Enum.sort() == [:email, :google]
    end

    test "Journey 2: an Apple-only fighter links the address and accepts the E08 link (SF-57)" do
      coach = inviting_coach!()
      email = address()
      {invitation, invitation_token} = invite_to!(coach, email)
      token = apple_sign_in("000777.journey#{System.unique_integer([:positive])}", email)
      user = user_of(token)
      SimpleFit.FighterOnboardingHelpers.complete_fighter_onboarding!(user)

      accept = fn ->
        token
        |> authed()
        |> post_json("/api/v1/me/coach-invitations/accept", %{
          token: invitation_token,
          disclosure_version: version(),
          document_language: "en"
        })
      end

      # The token alone is not mailbox ownership.
      reset_rate_limits()
      error(accept.(), 403, "invitation_recipient_mismatch")

      link!(token, email)
      reset_rate_limits()
      assert json_response(accept.(), 200)["outcome"] == "created"
      assert Repo.get!(Invitation, invitation.id).status == :accepted

      assert Repo.all(from(i in Identity, where: i.user_id == ^user.id, select: i.provider))
             |> Enum.sort() == [:apple, :email]
    end

    test "Journey 6: with sharing off the linked address still reaches no invitation" do
      coach = inviting_coach!()
      email = address()
      {invitation, _token} = invite_to!(coach, email)
      token = google_sign_in("off-#{System.unique_integer([:positive])}", "x@example.com")
      user = user_of(token)
      SimpleFit.FighterOnboardingHelpers.complete_fighter_onboarding!(user)
      link!(token, email)

      set_sharing(enabled: false)

      error(inbox(token), 404, "not_found")
      reset_rate_limits()
      error(accept_by_id(token, invitation.id), 404, "not_found")
      assert Repo.get!(Invitation, invitation.id).status == :pending
      assert Repo.aggregate(Relationship, :count) == 0
      # The identity itself does not depend on sharing.
      assert Accounts.verified_email_addresses(user) == [email]
    end
  end
end
