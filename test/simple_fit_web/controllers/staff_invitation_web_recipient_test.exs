defmodule SimpleFitWeb.StaffInvitationWebRecipientTest do
  @moduledoc """
  What the web recipient page needs (SF-133): the delivery gate of E06
  (`staff_invitations`, off unless explicitly on) and `resolveStaffInvitation`,
  the token's invitation for its signed-in recipient in any status. OpenAPI
  schemas, `no-store`, no state oracle for anyone else.
  """

  # Not async: switches the gym configuration.
  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions
  import SimpleFit.EmailAuthHelpers, only: [emails_to: 1]
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Gyms, Repo}
  alias SimpleFit.Gyms.{StaffInvitation, StaffMembership}
  alias SimpleFitWeb.ApiSpec

  @resolve "/api/v1/me/staff-invitations/resolve"

  defp bearer(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(user),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> bearer(user))
      |> put_req_header("content-type", "application/json")

  defp resolve(user, token),
    do: user |> authed() |> post(@resolve, Jason.encode!(%{token: token}))

  defp invitation(conn) do
    body = json_response(conn, 200)
    assert_schema(body, "MyStaffInvitationResponse", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body["invitation"]
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  defp gates(value) do
    original = Application.get_env(:simple_fit, Gyms)
    Application.put_env(:simple_fit, Gyms, Keyword.put(original, :staff_invitations, value))
    on_exit(fn -> Application.put_env(:simple_fit, Gyms, original) end)
  end

  setup do
    Repo.delete_all("rate_limit_events")
    owner = registered_as!(registered!("staff-web-owner"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym}
  end

  describe "the delivery gate" do
    for value <- [false, nil, "enabled"] do
      test "#{inspect(value)} sends nothing, creates nothing and says why", ctx do
        gates(unquote(value))
        email = address("gated")

        details =
          ctx.owner
          |> authed()
          |> post(
            "/api/v1/gyms/#{ctx.gym.id}/staff-invitations",
            Jason.encode!(%{email: email, role: "coach"})
          )
          |> error(409, "conflict")

        assert details["details"] == %{"staff_invitation" => "recipient_flow_unavailable"}
        assert Repo.aggregate(StaffInvitation, :count) == 0
        assert emails_to(email) == []
      end
    end

    test "resending stops too; an issued invitation can still be answered and cancelled", ctx do
      email = address("issued")
      user = email_user!(email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)
      before = length(emails_to(email))
      gates(false)

      assert ctx.owner
             |> authed()
             |> post("/api/v1/gyms/#{ctx.gym.id}/staff-invitations/#{id}/resend")
             |> error(409, "conflict")
             |> Map.fetch!("details") ==
               %{"staff_invitation" => "recipient_flow_unavailable"}

      assert length(emails_to(email)) == before
      assert {:ok, _} = Gyms.preview_staff_invitation(token, client_ip())
      assert %{"status" => "pending"} = user |> resolve(token) |> invitation()

      assert {:ok, %{outcome: :accepted}} =
               Gyms.accept_staff_invitation(
                 user,
                 live_session!(user),
                 {:token, token},
                 client_ip()
               )
    end

    test "access checks come first: outsiders still get 404, a coach 403", ctx do
      gates(false)
      body = Jason.encode!(%{email: address("x"), role: "coach"})
      {coach, _} = joined_staff_before_gate(ctx)

      registered!("staff-web-out")
      |> authed()
      |> post("/api/v1/gyms/#{ctx.gym.id}/staff-invitations", body)
      |> error(404, "not_found")

      coach
      |> authed()
      |> post("/api/v1/gyms/#{ctx.gym.id}/staff-invitations", body)
      |> error(403, "forbidden")
    end
  end

  # Joined with the gate open, as staff already at the gym when it closes.
  defp joined_staff_before_gate(ctx) do
    original = Application.get_env(:simple_fit, Gyms)
    Application.put_env(:simple_fit, Gyms, Keyword.put(original, :staff_invitations, true))
    joined = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Cody Coach")
    Application.put_env(:simple_fit, Gyms, Keyword.put(original, :staff_invitations, false))
    joined
  end

  describe "resolveStaffInvitation" do
    test "needs a session", ctx do
      email = address()
      invite!(ctx.owner, ctx.gym.id, email, :coach)

      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(@resolve, Jason.encode!(%{token: staff_token_for(email)}))
      |> error(401, "unauthorized")
    end

    test "the recipient sees each status; reading changes nothing", ctx do
      email = address("states")
      user = email_user!(email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :manager)
      token = staff_token_for(email)

      assert %{
               "status" => "pending",
               "role" => "manager",
               "sent_to" => ^email,
               "gym" => %{"gym_id" => gym_id, "name" => "Simple Boxing Gym"},
               "staff_membership_id" => nil
             } = user |> resolve(token) |> invitation()

      assert gym_id == ctx.gym.id
      assert active_memberships(ctx.gym.id, user) == []
      assert stored_invitation(id).status == :pending

      {:ok, accepted} =
        Gyms.accept_staff_invitation(user, live_session!(user), {:token, token}, client_ip())

      assert %{"status" => "accepted", "staff_membership_id" => membership} =
               user |> resolve(token) |> invitation()

      assert membership == accepted.staff_membership_id
    end

    test "declined, cancelled and expired are told apart for the recipient only", ctx do
      other = email_user!(address("other"))

      for {status, finish} <- [
            {"declined",
             fn user, _id, token ->
               {:ok, _} = Gyms.decline_staff_invitation(user, {:token, token}, client_ip())
             end},
            {"cancelled",
             fn _user, id, _token ->
               {:ok, _} = Gyms.cancel_staff_invitation(ctx.owner, ctx.gym.id, id)
             end},
            {"expired", fn _user, id, _token -> expire_invitation!(id) end}
          ] do
        email = address(status)
        user = email_user!(email)
        %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
        token = staff_token_for(email)
        finish.(user, id, token)

        assert %{"status" => ^status} = user |> resolve(token) |> invitation()
        # Anyone else learns nothing: the same answer as an unknown token.
        other |> resolve(token) |> error(410, "invitation_unavailable")

        assert {:error, :invitation_unavailable} =
                 Gyms.preview_staff_invitation(token, client_ip())
      end
    end

    test "another account: mismatch while current, nothing about the invitation", ctx do
      email = address("invited")
      other = email_user!(address("someone"))
      invite!(ctx.owner, ctx.gym.id, email, :manager)
      token = staff_token_for(email)

      refusal = other |> resolve(token) |> error(403, "invitation_recipient_mismatch")
      refute inspect(refusal) =~ email
      refute inspect(refusal) =~ ctx.gym.id
      assert active_memberships(ctx.gym.id, other) == []
    end

    test "a Google-only user is not the recipient until they verify the address", ctx do
      email = address("linked")
      user = registered_as!(registered!("staff-web-google"), "Gosia Google")
      invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)

      user |> resolve(token) |> error(403, "invitation_recipient_mismatch")
      link_email!(user, email)
      assert %{"status" => "pending"} = user |> resolve(token) |> invitation()

      assert {:ok, %{outcome: :accepted, role: :coach}} =
               Gyms.accept_staff_invitation(
                 user,
                 live_session!(user),
                 {:token, token},
                 client_ip()
               )

      assert Repo.aggregate(
               from(m in StaffMembership,
                 where: m.gym_id == ^ctx.gym.id and m.user_id == ^user.id
               ),
               :count
             ) == 1
    end

    test "malformed and unknown tokens are 410; the token never reaches the log", ctx do
      user = email_user!(address("probe"))
      email = address("logged")
      invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)

      log =
        capture_log([level: :debug], fn ->
          for bad <- ["nope", "sfs_" <> String.duplicate("a", 43), nil, 12] do
            user
            |> authed()
            |> post(@resolve, Jason.encode!(%{token: bad}))
            |> error(410, "invitation_unavailable")
          end

          user |> resolve(token) |> error(403, "invitation_recipient_mismatch")
        end)

      refute log =~ token
      refute log =~ email
    end

    test "is rate limited with previews and answers", ctx do
      email = address("limit")
      user = email_user!(email)
      invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)

      statuses = for _ <- 1..31, do: resolve(user, token).status
      assert List.last(statuses) == 429
      assert Enum.count(statuses, &(&1 == 200)) == 30
    end
  end
end
