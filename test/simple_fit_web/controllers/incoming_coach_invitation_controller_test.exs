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

  # --- Responding by id (SF-73) --------------------------------------------

  defp by_id(who, action, id, body \\ %{}) do
    path = "#{@path}/#{id}/#{action}"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token_for(who))

    case action do
      "preview" ->
        get(conn, path)

      _ ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(body))
    end
  end

  test "with the production default, preview and accept by id answer 404; decline works" do
    coach = inviting_coach!()
    email = address()
    fighter = email_fighter!(email)
    {invitation, _} = invite_to!(coach, email)
    {other, _} = invite_to!(inviting_coach!("Coach B"), email)

    error(by_id(fighter, "preview", invitation.id), 404, "not_found")

    error(
      by_id(fighter, "accept", invitation.id, %{disclosure_version: version()}),
      404,
      "not_found"
    )

    assert Repo.aggregate(Relationship, :count) == 0
    assert by_id(fighter, "decline", other.id).status == 204
    assert Repo.get!(Invitation, other.id).status == :declined
  end

  describe "with responding by id enabled (test configuration)" do
    setup do
      set_sharing(id_acceptance: true)
      :ok
    end

    test "inbox → preview → explicit acceptance; repeats are 410" do
      coach = inviting_coach!("Coach Marek")
      email = address()
      fighter = email_fighter!(email)
      {_invitation, token} = invite_to!(coach, email)

      [entry] = page(get_inbox(fighter, "?status=pending"))["invitations"]
      id = entry["invitation_id"]

      conn = by_id(fighter, "preview", id)
      preview = json_response(conn, 200)
      assert_schema(preview, "CoachInvitationPreview", ApiSpec.spec())
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert preview["invitation"]["coach"]["display_name"] == "Coach Marek"
      refute conn.resp_body =~ token

      conn = by_id(fighter, "accept", id, %{disclosure_version: preview["disclosure"]["version"]})
      result = json_response(conn, 200)
      assert_schema(result, "CoachInvitationAcceptResponse", ApiSpec.spec())
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert result["outcome"] == "created"

      error(
        by_id(fighter, "accept", id, %{disclosure_version: version()}),
        410,
        "invitation_unavailable"
      )

      error(by_id(fighter, "preview", id), 410, "invitation_unavailable")

      conn =
        post_json(fighter, "/api/v1/me/coach-invitations/accept", %{
          token: token,
          disclosure_version: version()
        })

      error(conn, 410, "invitation_unavailable")
      assert Repo.aggregate(Relationship, :count) == 1

      assert [%{"status" => "accepted"}] = page(get_inbox(fighter))["invitations"]
      roster = json_response(get_with(coach, "/api/v1/me/coach/fighters"), 200)
      assert length(roster["relationships"]) == 1
    end

    test "foreign, unknown and malformed ids answer the same 410 for every user" do
      coach = inviting_coach!()
      email = address()
      _owner = email_fighter!(email)
      {invitation, _} = invite_to!(coach, email)

      stranger = email_fighter!(address())
      oauth_only = fighter_user!()

      for who <- [stranger, oauth_only, coach],
          id <- [invitation.id, Ecto.UUID.generate(), "not-a-uuid", "%27%20OR%201%3D1"],
          action <- ["preview", "accept", "decline"] do
        reset_rate_limits()
        conn = by_id(who, action, id, %{disclosure_version: version()})
        body = error(conn, 410, "invitation_unavailable")
        refute inspect(body) =~ invitation.id
      end

      assert Repo.get!(Invitation, invitation.id).status == :pending
      assert Repo.aggregate(Relationship, :count) == 0
    end

    test "errors: stale version, missing version, incomplete profiles, gate off, unauthenticated" do
      coach = inviting_coach!()
      email = address()
      {invitation, _} = invite_to!(coach, email)
      {:ok, user} = Accounts.register_user(:email, email)

      details = error(by_id(user, "preview", invitation.id), 422, "validation_error")["details"]
      assert details["fields"]["account_registration"]

      user = SimpleFit.AccountRegistrationHelpers.complete_account_registration!(user)

      details =
        error(
          by_id(user, "accept", invitation.id, %{disclosure_version: version()}),
          422,
          "validation_error"
        )["details"]

      assert details["fields"]["fighter_profile"]

      fighter = SimpleFit.FighterOnboardingHelpers.complete_fighter_onboarding!(user)
      reset_rate_limits()

      body =
        error(
          by_id(fighter, "accept", invitation.id, %{disclosure_version: "x"}),
          409,
          "conflict"
        )

      assert body["details"] == %{"disclosure_version" => "stale"}
      error(by_id(fighter, "accept", invitation.id, %{}), 422, "validation_error")

      set_sharing(enabled: false, id_acceptance: true)

      error(
        by_id(fighter, "accept", invitation.id, %{disclosure_version: version()}),
        404,
        "not_found"
      )

      error(by_id(fighter, "preview", invitation.id), 404, "not_found")

      for action <- ["preview", "accept", "decline"] do
        conn =
          if action == "preview",
            do: get(build_conn(), "#{@path}/#{invitation.id}/preview"),
            else: post(build_conn(), "#{@path}/#{invitation.id}/#{action}", %{})

        error(conn, 401, "unauthorized")
      end

      assert Repo.aggregate(Relationship, :count) == 0
    end

    test "canaries in ids, bodies and nested values never echo, log or 5xx" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      {invitation, token} = invite_to!(coach, email)

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      shapes = [
        "sfi_#{@canary}abcdefghijklmnopqrstuvwxyz0",
        "#{String.downcase(@canary)}@example.com",
        %{"nested" => @canary},
        [@canary],
        String.duplicate("A", 5_000) <> @canary,
        token
      ]

      log =
        capture_log([level: :debug], fn ->
          for shape <- shapes,
              id <- [invitation.id, URI.encode_www_form(@canary)],
              action <- ["preview", "accept", "decline"] do
            reset_rate_limits()

            body = %{
              "disclosure_version" => shape,
              "token" => shape,
              "email" => shape,
              "user_id" => shape,
              "recipient_digest" => shape
            }

            conn = by_id(fighter, action, id, body)
            assert conn.status < 500

            if conn.status >= 400 do
              refute conn.resp_body =~ @canary
              refute conn.resp_body =~ String.downcase(@canary)
              refute conn.resp_body =~ token
            end
          end
        end)

      refute log =~ @canary
      refute log =~ String.downcase(@canary)
      refute log =~ token
      refute log =~ email
      assert Repo.aggregate(Relationship, :count) == 0
    end
  end

  defp get_with(who, path) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token_for(who))
    |> get(path)
  end
end
