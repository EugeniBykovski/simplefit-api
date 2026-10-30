defmodule SimpleFitWeb.GymMemberControllerTest do
  @moduledoc """
  Gym members over HTTP (SF-95), with real sessions: every member,
  enrollment, member invitation and member-list operation, checked against
  the OpenAPI schemas, `no-store`, and 200 / 201 / 401 / 403 / 404 / 409 /
  410 / 422 / 429.
  """

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers

  alias SimpleFit.Accounts
  alias SimpleFitWeb.ApiSpec

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp anonymous, do: put_req_header(build_conn(), "content-type", "application/json")

  defp ok(conn, schema, status \\ 200) do
    body = json_response(conn, status)
    assert_schema(body, schema, ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  defp gym_path(gym_id, suffix), do: "/api/v1/gyms/#{gym_id}#{suffix}"
  defp body(map), do: Jason.encode!(map)

  setup do
    owner = registered_as!(registered!("members-http"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, token: token(owner)}
  end

  test "enrollment: code, auto-approval, join, preview, approve, roster, remove", ctx do
    settings =
      ctx.token
      |> authed()
      |> post(gym_path(ctx.gym.id, "/join-code/rotate"))
      |> ok("GymEnrollmentSettingsResponse")

    code = settings["enrollment"]["join_code"]
    assert code =~ ~r/^[0-9A-Z]{4}-[0-9A-Z]{4}$/
    assert settings["enrollment"]["auto_approve"] == false
    assert settings["enrollment"]["can_manage"] == true

    preview =
      anonymous()
      |> post("/api/v1/gym-join/preview", body(%{code: code}))
      |> ok("GymJoinPreviewResponse")

    assert preview["preview"] == %{
             "gym" => %{"name" => "Simple Boxing Gym"},
             "requires_approval" => true
           }

    anonymous()
    |> post("/api/v1/gym-join/preview", body(%{code: "ZZZZ-ZZZZ"}))
    |> error(404, "not_found")

    member = email_user!(address("http-member"), "Marta Kowalska")
    mtoken = token(member)

    joined =
      mtoken
      |> authed()
      |> post("/api/v1/me/gym-memberships/join", body(%{code: code}))
      |> ok("MyGymMembershipResponse", 201)

    assert %{"status" => "requested", "joined_via" => "join_code"} = joined["membership"]
    id = joined["membership"]["gym_member_id"]

    mtoken
    |> authed()
    |> post("/api/v1/me/gym-memberships/join", body(%{code: code}))
    |> ok("MyGymMembershipResponse", 200)

    mtoken
    |> authed()
    |> post("/api/v1/me/gym-memberships/join", body(%{code: "ZZZZ-ZZZZ"}))
    |> error(404, "not_found")

    requests =
      ctx.token |> authed() |> get(gym_path(ctx.gym.id, "/join-requests")) |> ok("GymMemberList")

    assert [%{"gym_member_id" => ^id, "name" => "Marta K."}] = requests["members"]

    approved =
      ctx.token
      |> authed()
      |> post(gym_path(ctx.gym.id, "/join-requests/#{id}/approve"))
      |> ok("GymMemberResponse")

    assert approved["member"]["status"] == "active"

    ctx.token
    |> authed()
    |> post(gym_path(ctx.gym.id, "/join-requests/#{id}/reject"))
    |> error(409, "conflict")
    |> then(&assert(&1["details"] == %{"gym_member" => "active"}))

    mtoken
    |> authed()
    |> post("/api/v1/me/gym-memberships/join", body(%{code: code}))
    |> error(409, "conflict")

    roster = ctx.token |> authed() |> get(gym_path(ctx.gym.id, "/members")) |> ok("GymMemberList")
    assert [%{"name" => "Marta K.", "status" => "active"}] = roster["members"]
    refute Jason.encode!(roster) =~ "@"

    ctx.token
    |> authed()
    |> get(gym_path(ctx.gym.id, "/members/#{id}"))
    |> ok("GymMemberResponse")

    mine = mtoken |> authed() |> get("/api/v1/me/gym-memberships") |> ok("MyGymMembershipList")
    assert [%{"gym" => %{"name" => "Simple Boxing Gym"}}] = mine["memberships"]
    mtoken |> authed() |> get("/api/v1/me/gym-memberships/#{id}") |> ok("MyGymMembershipResponse")
    # A member has no staff access.
    mtoken |> authed() |> get(gym_path(ctx.gym.id, "/members")) |> error(404, "not_found")

    removed =
      ctx.token
      |> authed()
      |> post(gym_path(ctx.gym.id, "/members/#{id}/remove"))
      |> ok("GymMemberResponse")

    assert %{"status" => "ended", "ended_reason" => "removed"} = removed["member"]

    mtoken |> authed() |> post("/api/v1/me/gym-memberships/#{id}/leave") |> error(409, "conflict")

    switched =
      ctx.token
      |> authed()
      |> patch(gym_path(ctx.gym.id, "/enrollment"), body(%{auto_approve: true}))
      |> ok("GymEnrollmentSettingsResponse")

    assert switched["enrollment"]["auto_approve"] == true

    ctx.token
    |> authed()
    |> patch(gym_path(ctx.gym.id, "/enrollment"), body(%{auto_approve: true, extra: 1}))
    |> error(422, "validation_error")

    auto =
      mtoken
      |> authed()
      |> post("/api/v1/me/gym-memberships/join", body(%{code: code}))
      |> ok("MyGymMembershipResponse", 201)

    assert %{"status" => "active", "auto_approved" => true} = auto["membership"]
    auto_id = auto["membership"]["gym_member_id"]

    left =
      mtoken
      |> authed()
      |> post("/api/v1/me/gym-memberships/#{auto_id}/leave")
      |> ok("MyGymMembershipResponse")

    assert left["membership"]["ended_reason"] == "left"

    ctx.token
    |> authed()
    |> get(gym_path(ctx.gym.id, "/enrollment"))
    |> ok("GymEnrollmentSettingsResponse")

    disabled =
      ctx.token
      |> authed()
      |> post(gym_path(ctx.gym.id, "/join-code/disable"))
      |> ok("GymEnrollmentSettingsResponse")

    assert disabled["enrollment"]["join_code"] == nil
  end

  test "cancel a request; registration required; permissions and unauthenticated calls", ctx do
    code = join_code!(ctx.owner, ctx.gym.id)
    member = email_user!(address("cancel"))
    mtoken = token(member)

    joined =
      mtoken
      |> authed()
      |> post("/api/v1/me/gym-memberships/join", body(%{code: code}))
      |> ok("MyGymMembershipResponse", 201)

    id = joined["membership"]["gym_member_id"]

    cancelled =
      mtoken
      |> authed()
      |> post("/api/v1/me/gym-memberships/#{id}/cancel")
      |> ok("MyGymMembershipResponse")

    assert cancelled["membership"]["status"] == "cancelled"

    other = token(email_user!(address("other")))

    other
    |> authed()
    |> post("/api/v1/me/gym-memberships/#{id}/cancel")
    |> error(404, "not_found")

    other |> authed() |> get("/api/v1/me/gym-memberships/#{id}") |> error(404, "not_found")

    {:ok, unregistered} = Accounts.register_user(:email, address("unreg"))

    token(unregistered)
    |> authed()
    |> post("/api/v1/me/gym-memberships/join", body(%{code: code}))
    |> error(422, "validation_error")

    {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
    {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk)
    ctoken = token(coach)
    dtoken = token(desk)

    ctoken |> authed() |> get(gym_path(ctx.gym.id, "/members")) |> error(403, "forbidden")
    ctoken |> authed() |> get(gym_path(ctx.gym.id, "/join-requests")) |> error(403, "forbidden")

    dtoken
    |> authed()
    |> post(gym_path(ctx.gym.id, "/join-code/rotate"))
    |> error(403, "forbidden")

    dtoken
    |> authed()
    |> get(gym_path(ctx.gym.id, "/enrollment"))
    |> ok("GymEnrollmentSettingsResponse")

    dtoken
    |> authed()
    |> get(gym_path(ctx.gym.id, "/members?status=bogus"))
    |> error(422, "validation_error")

    anonymous() |> get("/api/v1/me/gym-memberships") |> error(401, "unauthorized")

    anonymous()
    |> post("/api/v1/me/gym-memberships/join", body(%{code: code}))
    |> error(401, "unauthorized")

    anonymous() |> get(gym_path(ctx.gym.id, "/members")) |> error(401, "unauthorized")
  end

  test "member invitations: invite, inbox, preview, accept by token, decline, resend, cancel",
       ctx do
    path = gym_path(ctx.gym.id, "/member-invitations")
    email = address("http-inv")
    recipient = email_user!(email, "Ola Nowak")
    rtoken = token(recipient)

    created =
      ctx.token
      |> authed()
      |> post(path, body(%{email: email}))
      |> ok("GymMemberInvitationResponse", 201)

    refute Jason.encode!(created) =~ email

    ctx.token
    |> authed()
    |> post(path, body(%{email: email}))
    |> ok("GymMemberInvitationResponse", 200)

    ctx.token |> authed() |> post(path, body(%{email: "nope"})) |> error(422, "validation_error")
    ctx.token |> authed() |> get(path) |> ok("GymMemberInvitationList")

    inbox = rtoken |> authed() |> get("/api/v1/me/gym-invitations") |> ok("MyGymInvitationList")
    assert [%{"sent_to" => ^email}] = inbox["invitations"]
    id = created["invitation"]["invitation_id"]
    rtoken |> authed() |> get("/api/v1/me/gym-invitations/#{id}") |> ok("MyGymInvitationResponse")

    sgm = member_token_for(email)

    anonymous()
    |> post("/api/v1/gym-invitations/preview", body(%{token: sgm}))
    |> ok("GymInvitationPreviewResponse")

    anonymous()
    |> post("/api/v1/gym-invitations/preview", body(%{token: "sgm_x"}))
    |> error(410, "invitation_unavailable")

    stranger = token(email_user!(address("stranger")))

    stranger
    |> authed()
    |> post("/api/v1/me/gym-invitations/accept", body(%{token: sgm}))
    |> error(403, "invitation_recipient_mismatch")

    stranger |> authed() |> get("/api/v1/me/gym-invitations/#{id}") |> error(404, "not_found")

    accepted =
      rtoken
      |> authed()
      |> post("/api/v1/me/gym-invitations/accept", body(%{token: sgm}))
      |> ok("GymInvitationAcceptResponse")

    assert accepted["outcome"] == "accepted"

    again =
      rtoken
      |> authed()
      |> post("/api/v1/me/gym-invitations/#{id}/accept")
      |> ok("GymInvitationAcceptResponse")

    assert again["outcome"] == "already_accepted"
    ctx.token |> authed() |> post("#{path}/#{id}/cancel") |> error(409, "conflict")

    email2 = address("http-decline")
    r2 = token(email_user!(email2))

    second =
      ctx.token
      |> authed()
      |> post(path, body(%{email: email2}))
      |> ok("GymMemberInvitationResponse", 201)

    id2 = second["invitation"]["invitation_id"]
    ctx.token |> authed() |> post("#{path}/#{id2}/resend") |> error(429, "rate_limited")

    declined =
      r2
      |> authed()
      |> post("/api/v1/me/gym-invitations/#{id2}/decline")
      |> ok("MyGymInvitationResponse")

    assert declined["invitation"]["status"] == "declined"

    r2
    |> authed()
    |> post("/api/v1/me/gym-invitations/#{id2}/accept")
    |> error(410, "invitation_unavailable")

    email3 = address("http-cancel")

    third =
      ctx.token
      |> authed()
      |> post(path, body(%{email: email3}))
      |> ok("GymMemberInvitationResponse", 201)

    id3 = third["invitation"]["invitation_id"]

    cancelled =
      ctx.token |> authed() |> post("#{path}/#{id3}/cancel") |> ok("GymMemberInvitationResponse")

    assert cancelled["invitation"]["status"] == "cancelled"
    token3 = member_token_for(email3)

    token(email_user!(email3))
    |> authed()
    |> post("/api/v1/me/gym-invitations/decline", body(%{token: token3}))
    |> error(410, "invitation_unavailable")
  end

  test "member-list dry run over HTTP", ctx do
    path = gym_path(ctx.gym.id, "/member-imports/preview")

    csv =
      "name;email;plan\nMarta Kowalska;marta@example.com;Unlimited\nDup;MARTA@example.com;\n;bad;\n"

    preview =
      ctx.token
      |> authed()
      |> post(path, body(%{csv: csv}))
      |> ok("GymMemberImportPreviewResponse")

    assert preview["preview"]["persisted"] == false

    assert preview["preview"]["commit"] == %{
             "available" => false,
             "blocked_by" => "legal_basis_pending"
           }

    assert Enum.map(preview["preview"]["rows"], & &1["outcome"]) == [
             "ready",
             "duplicate",
             "invalid_email"
           ]

    refute Jason.encode!(preview) =~ "marta@example.com"
    refute Jason.encode!(preview) =~ "Unlimited"

    ctx.token
    |> authed()
    |> post(path, body(%{csv: "email\n\"open"}))
    |> error(422, "validation_error")

    ctx.token
    |> authed()
    |> post(path, body(%{csv: csv, commit: true}))
    |> error(422, "validation_error")

    {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
    token(coach) |> authed() |> post(path, body(%{csv: csv})) |> error(403, "forbidden")
  end
end
