defmodule SimpleFitWeb.IncomingCoachInvitationControllerTest do
  @moduledoc """
  The recipient's invitation inbox over HTTP on the real endpoints and
  PostgreSQL (SF-73): verified-identity matching, OpenAPI schemas, the gate,
  isolation between accounts and privacy (canaries in responses and logs).
  """

  # Not async: sharing configuration, queued emails and rate limits are shared.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaching.{Invitation, InvitationSecrets, Relationship}
  alias SimpleFitWeb.ApiSpec

  @canary "CANARYsf73inbx9Qe4Rt7Yu"
  @path "/api/v1/me/coach-invitations"

  setup do
    configure_sharing()
    reset_rate_limits()
    :ok
  end

  defp token_for(%User{} = user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp get_inbox(who, query \\ "")

  defp get_inbox(%User{} = user, query), do: get_inbox(token_for(user), query)

  defp get_inbox(token, query) when is_binary(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(@path <> query)
  end

  defp post_json(who, path, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token_for(who))
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp page(conn) do
    body = json_response(conn, 200)
    assert_schema(body, "IncomingCoachInvitationList", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body
  end

  defp error(conn, status, code) do
    body = json_response(conn, status)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    assert body["error"]["code"] == code
    body["error"]
  end

  defp address, do: "inbox-http-#{System.unique_integer([:positive])}@example.com"

  defp email_user!(address) do
    {:ok, user} = Accounts.register_user(:email, address)
    SimpleFit.AccountRegistrationHelpers.complete_account_registration!(user)
  end

  defp invite_to!(coach, email, attrs \\ %{}) do
    reset_rate_limits()
    invite!(coach, email, attrs)
  end

  test "the verified recipient reads the invitation, with the coach's public identity only" do
    coach = inviting_coach!("Coach Marek")
    email = address()
    {invitation, token} = invite_to!(coach, email, %{"message" => "Let's train"})
    user = email_user!(email)

    body = page(get_inbox(user))
    assert [entry] = body["invitations"]
    assert body["next_cursor"] == nil

    assert entry == %{
             "invitation_id" => invitation.id,
             "status" => "pending",
             "coach" => %{"display_name" => "Coach Marek", "brand_name" => "Marek Boxing"},
             "message" => "Let's train",
             "created_at" => DateTime.to_iso8601(invitation.inserted_at),
             "expires_at" => DateTime.to_iso8601(invitation.expires_at),
             "responded_at" => nil
           }

    raw = get_inbox(user).resp_body
    row = Repo.get!(Invitation, invitation.id)
    refute raw =~ token
    refute raw =~ email
    refute raw =~ row.recipient_sealed
    refute raw =~ Base.encode64(row.recipient_digest)
    refute raw =~ Base.encode64(row.token_hash)
    refute raw =~ "token"
    refute raw =~ "digest"
    assert Repo.aggregate(Relationship, :count) == 0
  end

  test "authentication is required" do
    error(get(build_conn(), @path), 401, "unauthorized")
  end

  test "wrong recipient, OAuth-only and other coaches see nothing" do
    coach = inviting_coach!()
    email = address()
    {_invitation, _} = invite_to!(coach, email)

    other_email_user = email_user!(address())
    oauth_only = registered_user!("oauth")
    other_coach = inviting_coach!("Coach B")

    for who <- [other_email_user, oauth_only, other_coach, coach] do
      assert page(get_inbox(who))["invitations"] == []
    end
  end

  test "request parameters cannot choose the recipient" do
    coach = inviting_coach!()
    victim = address()
    {_invitation, _} = invite_to!(coach, victim)
    attacker = email_user!(address())
    digest = Base.url_encode64(InvitationSecrets.recipient_digest(victim))

    for query <- [
          "?email=#{URI.encode_www_form(victim)}",
          "?recipient_email=#{URI.encode_www_form(victim)}",
          "?user_id=#{Ecto.UUID.generate()}",
          "?recipient_digest=#{digest}",
          "?coach_profile_id=#{SimpleFit.Coaches.get_profile(coach).id}"
        ] do
      assert page(get_inbox(attacker, query))["invitations"] == []
    end
  end

  test "an invitation id is not a resource: no detail route exists" do
    coach = inviting_coach!()
    email = address()
    {invitation, _} = invite_to!(coach, email)
    owner = email_user!(email)
    stranger = email_user!(address())

    for who <- [owner, stranger] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token_for(who))
        |> get("#{@path}/#{invitation.id}")

      assert conn.status == 404
      refute conn.resp_body =~ invitation.id
    end
  end

  test "status filter and invalid parameters" do
    coach = inviting_coach!()
    email = address()
    {invitation, _} = invite_to!(coach, email)
    user = email_user!(email)

    assert [%{"invitation_id" => id}] = page(get_inbox(user, "?status=pending"))["invitations"]
    assert id == invitation.id
    assert page(get_inbox(user, "?status=declined"))["invitations"] == []

    for query <- [
          "?status=active",
          "?limit=0",
          "?limit=101",
          "?cursor=%25%25",
          "?status[]=pending"
        ] do
      error(get_inbox(user, query), 422, "validation_error")
    end
  end

  test "with sharing disabled the inbox answers 404, not an empty page" do
    coach = inviting_coach!()
    email = address()
    {_invitation, _} = invite_to!(coach, email)
    user = email_user!(email)

    set_sharing(enabled: false)
    conn = get_inbox(user)
    error(conn, 404, "not_found")
    refute conn.resp_body =~ "Coach Marek"
  end

  test "an incomplete account registration is a prerequisite error" do
    coach = inviting_coach!()
    email = address()
    {_invitation, _} = invite_to!(coach, email)
    {:ok, user} = Accounts.register_user(:email, email)

    details = error(get_inbox(user), 422, "validation_error")["details"]
    assert details["fields"]["account_registration"]
  end

  test "D. a token acceptance shows as accepted, with no second invitation or relationship" do
    coach = inviting_coach!()
    email = address()
    fighter = email_fighter!(email)
    {invitation, token} = invite_to!(coach, email)

    conn =
      post_json(fighter, "/api/v1/me/coach-invitations/accept", %{
        token: token,
        disclosure_version: version()
      })

    assert json_response(conn, 200)["outcome"] == "created"

    assert [%{"invitation_id" => id, "status" => "accepted", "responded_at" => at}] =
             page(get_inbox(fighter))["invitations"]

    assert id == invitation.id
    assert is_binary(at)
    assert Repo.aggregate(Invitation, :count) == 1
    assert Repo.aggregate(Relationship, :count) == 1
  end

  test "canaries in query parameters and notes never reach errors, other users or logs" do
    coach = inviting_coach!()
    email = address()
    {_invitation, token} = invite_to!(coach, email, %{"message" => "Note #{@canary}"})
    owner = email_user!(email)
    stranger = email_user!(address())

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      capture_log([level: :debug], fn ->
        for value <- [
              @canary,
              "sfi_#{@canary}",
              "#{String.downcase(@canary)}@example.com",
              Base.url_encode64("#{@canary}|#{@canary}", padding: false),
              String.duplicate("A", 5_000) <> @canary
            ],
            param <- ~w(cursor status limit email token nested[deep]) do
          conn = get_inbox(stranger, "?#{param}=#{URI.encode_www_form(value)}")
          assert conn.status < 500

          refute conn.resp_body =~ @canary
          refute conn.resp_body =~ String.downcase(@canary)
        end

        # The owner legitimately sees the coach's note and name.
        body = page(get_inbox(owner))
        assert [%{"message" => "Note " <> @canary}] = body["invitations"]
      end)

    refute log =~ @canary
    refute log =~ String.downcase(@canary)
    refute log =~ token
    refute log =~ email
  end
end
