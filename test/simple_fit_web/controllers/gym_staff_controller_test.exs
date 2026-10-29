defmodule SimpleFitWeb.GymStaffControllerTest do
  @moduledoc """
  Gym staff and staff invitations over HTTP (SF-93), with real sessions:
  `listGymStaff`, `changeGymStaffRole`, `endGymStaffMembership`,
  `createGymStaffInvitation`, `listGymStaffInvitations`,
  `resendGymStaffInvitation`, `cancelGymStaffInvitation`,
  `listMyStaffInvitations`, `getMyStaffInvitation`, `acceptMyStaffInvitation`,
  `declineMyStaffInvitation`, `acceptStaffInvitation`,
  `declineStaffInvitation` and `previewStaffInvitation`. OpenAPI schemas,
  `no-store`, and 200 / 201 / 401 / 403 / 404 / 409 / 410 / 422 / 429.
  """

  use SimpleFitWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Gyms.StaffInvitation
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

  defp staff_path(gym_id, suffix \\ ""), do: "/api/v1/gyms/#{gym_id}/staff#{suffix}"
  defp inv_path(gym_id, suffix \\ ""), do: "/api/v1/gyms/#{gym_id}/staff-invitations#{suffix}"

  defp invite(token, gym_id, email, role),
    do: token |> authed() |> post(inv_path(gym_id), Jason.encode!(%{email: email, role: role}))

  setup do
    owner = registered_as!(registered!("staff-http"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, token: token(owner)}
  end

  describe "the journey: invite, inbox, accept, roster, role, removal" do
    test "the owner invites; the recipient accepts from the inbox; the roster and gym follow",
         ctx do
      email = address("http")
      recipient = email_user!(email, "Natalia Wiśniewska")
      rtoken = token(recipient)

      created =
        ctx.token
        |> invite(ctx.gym.id, email, "manager")
        |> ok("GymStaffInvitationResponse", 201)

      assert %{"status" => "pending", "role" => "manager", "resends_remaining" => 3} =
               created["invitation"]

      refute Jason.encode!(created) =~ email
      id = created["invitation"]["invitation_id"]

      # Repeating it is safe.
      ctx.token |> invite(ctx.gym.id, email, "manager") |> ok("GymStaffInvitationResponse", 200)

      inbox =
        rtoken |> authed() |> get("/api/v1/me/staff-invitations") |> ok("MyStaffInvitationList")

      assert [%{"invitation_id" => ^id, "sent_to" => ^email} = entry] = inbox["invitations"]
      assert entry["gym"] == %{"gym_id" => ctx.gym.id, "name" => "Simple Boxing Gym"}
      assert entry["invited_by"] == %{"first_name" => "Yauheni", "role" => "owner"}

      rtoken
      |> authed()
      |> get("/api/v1/me/staff-invitations/#{id}")
      |> ok("MyStaffInvitationResponse")

      accepted =
        rtoken
        |> authed()
        |> post("/api/v1/me/staff-invitations/#{id}/accept")
        |> ok("StaffInvitationAcceptResponse")

      assert %{"outcome" => "accepted", "role" => "manager", "gym_id" => gym_id} = accepted
      assert gym_id == ctx.gym.id

      again =
        rtoken
        |> authed()
        |> post("/api/v1/me/staff-invitations/#{id}/accept")
        |> ok("StaffInvitationAcceptResponse")

      assert again["outcome"] == "already_accepted"
      assert again["staff_membership_id"] == accepted["staff_membership_id"]

      gym = rtoken |> authed() |> get("/api/v1/gyms/#{ctx.gym.id}") |> ok("GymResponse")
      assert gym["gym"]["viewer"]["role"] == "manager"
      assert "invite_staff" in gym["gym"]["viewer"]["permissions"]

      entry = rtoken |> authed() |> get("/api/v1/me/entry") |> json_response(200)
      assert Enum.any?(entry["entry"]["gym_workspaces"], &(&1["gym_id"] == ctx.gym.id))

      roster = rtoken |> authed() |> get(staff_path(ctx.gym.id)) |> ok("GymStaffList")

      assert Enum.map(roster["staff"], &{&1["role"], &1["name"]}) == [
               {"owner", "Yauheni B."},
               {"manager", "Natalia W."}
             ]

      # The owner changes the role, then removes the member: access ends on the next request.
      membership_id = accepted["staff_membership_id"]

      changed =
        ctx.token
        |> authed()
        |> patch(staff_path(ctx.gym.id, "/#{membership_id}"), Jason.encode!(%{role: "coach"}))
        |> ok("GymStaffMemberResponse")

      assert changed["staff_member"]["role"] == "coach"

      ended =
        ctx.token
        |> authed()
        |> delete(staff_path(ctx.gym.id, "/#{membership_id}"))
        |> ok("GymStaffMemberResponse")

      assert %{"status" => "ended", "ended_reason" => "removed"} = ended["staff_member"]
      rtoken |> authed() |> get("/api/v1/gyms/#{ctx.gym.id}") |> error(404, "not_found")
      rtoken |> authed() |> get(staff_path(ctx.gym.id)) |> error(404, "not_found")
      # The session itself still works.
      rtoken |> authed() |> get("/api/v1/me/staff-invitations") |> ok("MyStaffInvitationList")

      # The owner sees the history.
      history =
        ctx.token
        |> authed()
        |> get(staff_path(ctx.gym.id) <> "?status=ended")
        |> ok("GymStaffList")

      assert [%{"staff_membership_id" => ^membership_id}] = history["staff"]

      first_run =
        ctx.token |> authed() |> get("/api/v1/gyms/#{ctx.gym.id}/first-run") |> json_response(200)

      assert %{"key" => "invite_staff", "status" => "completed"} in first_run["first_run"][
               "checklist"
             ]
    end

    test "the web link: preview anonymously, accept and decline by token", ctx do
      email = address("web")
      recipient = email_user!(email)

      ctx.token
      |> invite(ctx.gym.id, email, "front_desk")
      |> ok("GymStaffInvitationResponse", 201)

      link_token = staff_token_for(email)

      preview =
        anonymous()
        |> post("/api/v1/staff-invitations/preview", Jason.encode!(%{token: link_token}))
        |> ok("StaffInvitationPreviewResponse")

      assert preview["preview"]["gym"] == %{"name" => "Simple Boxing Gym"}
      assert preview["preview"]["role"] == "front_desk"
      refute Jason.encode!(preview) =~ email

      intruder = token(email_user!(address("intruder")))

      intruder
      |> authed()
      |> post("/api/v1/me/staff-invitations/accept", Jason.encode!(%{token: link_token}))
      |> error(403, "invitation_recipient_mismatch")

      recipient
      |> token()
      |> authed()
      |> post("/api/v1/me/staff-invitations/accept", Jason.encode!(%{token: link_token}))
      |> ok("StaffInvitationAcceptResponse")

      anonymous()
      |> post("/api/v1/staff-invitations/preview", Jason.encode!(%{token: link_token}))
      |> error(410, "invitation_unavailable")

      # Decline by token, on a second invitation.
      other_email = address("decline")
      decliner = email_user!(other_email)

      ctx.token
      |> invite(ctx.gym.id, other_email, "coach")
      |> ok("GymStaffInvitationResponse", 201)

      other_token = staff_token_for(other_email)

      declined =
        decliner
        |> token()
        |> authed()
        |> post("/api/v1/me/staff-invitations/decline", Jason.encode!(%{token: other_token}))
        |> ok("MyStaffInvitationResponse")

      assert declined["invitation"]["status"] == "declined"
    end
  end

  describe "errors" do
    test "401 without a session on every authenticated operation", ctx do
      id = Ecto.UUID.generate()

      for {method, path} <- [
            {:get, staff_path(ctx.gym.id)},
            {:patch, staff_path(ctx.gym.id, "/#{id}")},
            {:delete, staff_path(ctx.gym.id, "/#{id}")},
            {:get, inv_path(ctx.gym.id)},
            {:post, inv_path(ctx.gym.id)},
            {:post, inv_path(ctx.gym.id, "/#{id}/resend")},
            {:post, inv_path(ctx.gym.id, "/#{id}/cancel")},
            {:get, "/api/v1/me/staff-invitations"},
            {:get, "/api/v1/me/staff-invitations/#{id}"},
            {:post, "/api/v1/me/staff-invitations/#{id}/accept"},
            {:post, "/api/v1/me/staff-invitations/#{id}/decline"},
            {:post, "/api/v1/me/staff-invitations/accept"},
            {:post, "/api/v1/me/staff-invitations/decline"}
          ] do
        anonymous() |> dispatch(@endpoint, method, path, "{}") |> error(401, "unauthorized")
      end
    end

    test "404 for outsiders, unknown and malformed gyms; 403 for staff without the permission",
         ctx do
      outsider = token(registered!("outsider"))
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
      coach_token = token(coach)

      for gym_id <- [ctx.gym.id, Ecto.UUID.generate(), "nope"] do
        outsider |> authed() |> get(staff_path(gym_id)) |> error(404, "not_found")
        outsider |> authed() |> get(inv_path(gym_id)) |> error(404, "not_found")
        outsider |> invite(gym_id, address(), "coach") |> error(404, "not_found")
      end

      coach_token |> authed() |> get(staff_path(ctx.gym.id)) |> ok("GymStaffList")

      coach_token
      |> authed()
      |> get(staff_path(ctx.gym.id) <> "?status=ended")
      |> error(403, "forbidden")

      coach_token |> authed() |> get(inv_path(ctx.gym.id)) |> error(403, "forbidden")
      coach_token |> invite(ctx.gym.id, address(), "coach") |> error(403, "forbidden")
    end

    test "409 and 422 on invitations", ctx do
      email = address()
      ctx.token |> invite(ctx.gym.id, email, "coach") |> ok("GymStaffInvitationResponse", 201)

      err = ctx.token |> invite(ctx.gym.id, email, "manager") |> error(409, "conflict")
      assert err["details"] == %{"staff_invitation" => "pending_other_role"}

      err = ctx.token |> invite(ctx.gym.id, address(), "owner") |> error(422, "validation_error")
      assert Map.has_key?(err["details"]["fields"], "role")

      err =
        ctx.token
        |> authed()
        |> post(
          inv_path(ctx.gym.id),
          Jason.encode!(%{email: address(), role: "coach", gym_id: Ecto.UUID.generate()})
        )
        |> error(422, "validation_error")

      assert Map.has_key?(err["details"]["fields"], "gym_id")

      draft_owner = registered!("draft")
      draft = draft_gym!(draft_owner)

      err =
        draft_owner |> token() |> invite(draft.id, address(), "coach") |> error(409, "conflict")

      assert err["details"] == %{"setup_status" => "draft"}
    end

    test "role change and removal errors", ctx do
      [owner_row] = active_owners(ctx.gym.id)

      {manager, %{staff_membership_id: manager_id}} =
        joined_staff!(ctx.owner, ctx.gym.id, :manager)

      mtoken = token(manager)

      err =
        ctx.token
        |> authed()
        |> patch(staff_path(ctx.gym.id, "/#{owner_row.id}"), Jason.encode!(%{role: "manager"}))
        |> error(409, "conflict")

      assert err["details"] == %{"staff_membership" => "owner_requires_transfer"}

      mtoken
      |> authed()
      |> patch(staff_path(ctx.gym.id, "/#{manager_id}"), Jason.encode!(%{role: "coach"}))
      |> error(403, "forbidden")

      ctx.token
      |> authed()
      |> patch(staff_path(ctx.gym.id, "/#{manager_id}"), Jason.encode!(%{role: "owner"}))
      |> error(422, "validation_error")

      ctx.token
      |> authed()
      |> patch(
        staff_path(ctx.gym.id, "/#{Ecto.UUID.generate()}"),
        Jason.encode!(%{role: "coach"})
      )
      |> error(404, "not_found")

      ctx.token
      |> authed()
      |> delete(staff_path(ctx.gym.id, "/#{owner_row.id}"))
      |> error(409, "conflict")

      mtoken
      |> authed()
      |> delete(staff_path(ctx.gym.id, "/#{owner_row.id}"))
      |> error(403, "forbidden")

      # Leaving.
      left =
        mtoken
        |> authed()
        |> delete(staff_path(ctx.gym.id, "/#{manager_id}"))
        |> ok("GymStaffMemberResponse")

      assert %{"ended_reason" => "left", "is_viewer" => true} = left["staff_member"]
    end

    test "410 and 404 for answers; 422 without registration", ctx do
      email = address()
      {:ok, unregistered} = Accounts.register_user(:email, email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      utoken = token(unregistered)

      err =
        utoken
        |> authed()
        |> post("/api/v1/me/staff-invitations/#{id}/accept")
        |> error(422, "validation_error")

      assert Map.has_key?(err["details"]["fields"], "account_registration")

      registered_as!(unregistered, "Kuba Nowak")
      expire_invitation!(id)

      utoken
      |> authed()
      |> post("/api/v1/me/staff-invitations/#{id}/accept")
      |> error(410, "invitation_unavailable")

      utoken
      |> authed()
      |> post("/api/v1/me/staff-invitations/#{id}/decline")
      |> error(410, "invitation_unavailable")

      other = token(email_user!(address("other")))
      other |> authed() |> get("/api/v1/me/staff-invitations/#{id}") |> error(404, "not_found")

      other
      |> authed()
      |> post("/api/v1/me/staff-invitations/#{id}/accept")
      |> error(404, "not_found")

      other
      |> authed()
      |> post("/api/v1/me/staff-invitations/accept", Jason.encode!(%{token: "sfs_forged"}))
      |> error(410, "invitation_unavailable")
    end

    test "resend and cancel", ctx do
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, address(), :coach)

      err =
        ctx.token
        |> authed()
        |> post(inv_path(ctx.gym.id, "/#{id}/resend"))
        |> error(429, "rate_limited")

      assert err["details"] == %{}

      Repo.update_all(from(i in StaffInvitation, where: i.id == ^id),
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -120)]
      )

      ctx.token
      |> authed()
      |> post(inv_path(ctx.gym.id, "/#{id}/resend"))
      |> ok("GymStaffInvitationResponse")

      cancelled =
        ctx.token
        |> authed()
        |> post(inv_path(ctx.gym.id, "/#{id}/cancel"))
        |> ok("GymStaffInvitationResponse")

      assert cancelled["invitation"]["status"] == "cancelled"

      list =
        ctx.token
        |> authed()
        |> get(inv_path(ctx.gym.id) <> "?status=cancelled")
        |> ok("GymStaffInvitationList")

      assert [%{"invitation_id" => ^id}] = list["invitations"]

      ctx.token
      |> authed()
      |> post(inv_path(ctx.gym.id, "/#{Ecto.UUID.generate()}/cancel"))
      |> error(404, "not_found")
    end

    test "429 for previews and answers after 30 per 10 minutes per client" do
      ip_conn = fn ->
        anonymous()
        |> Map.put(:remote_ip, {10, 93, 0, 1})
        |> post("/api/v1/staff-invitations/preview", Jason.encode!(%{token: "sfs_x"}))
      end

      for _ <- 1..30, do: ip_conn.() |> error(410, "invitation_unavailable")
      ip_conn.() |> error(429, "rate_limited")
    end
  end
end
