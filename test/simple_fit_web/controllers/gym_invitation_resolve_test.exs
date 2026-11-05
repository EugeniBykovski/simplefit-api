defmodule SimpleFitWeb.GymInvitationResolveTest do
  @moduledoc """
  `resolveGymInvitation` (SF-134): the E07 token's invitation for its signed-in
  recipient in any status, what the web recipient page needs. OpenAPI schemas,
  `no-store`, no state oracle for anyone else, and reading changes nothing.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Gyms, Repo}
  alias SimpleFit.Gyms.{Member, MemberInvitation}
  alias SimpleFitWeb.ApiSpec

  @resolve "/api/v1/me/gym-invitations/resolve"

  defp authed(user) do
    {:ok, credentials} = Accounts.create_session(user)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> credentials.access_token)
    |> put_req_header("content-type", "application/json")
  end

  defp resolve(user, token),
    do: user |> authed() |> post(@resolve, Jason.encode!(%{token: token}))

  defp invitation(conn) do
    body = json_response(conn, 200)
    assert_schema(body, "MyGymInvitationResponse", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body["invitation"]
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  defp expire!(id) do
    past = DateTime.add(DateTime.utc_now(), -1) |> DateTime.truncate(:microsecond)
    Repo.update_all(from(i in MemberInvitation, where: i.id == ^id), set: [expires_at: past])
  end

  setup do
    Repo.delete_all("rate_limit_events")
    owner = registered_as!(registered!("member-web-owner"), "Yauheni Bykovski")
    %{owner: owner, gym: completed_gym!(owner)}
  end

  test "needs a session", ctx do
    email = address()
    invite_member!(ctx.owner, ctx.gym.id, email)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(@resolve, Jason.encode!(%{token: member_token_for(email)}))
    |> error(401, "unauthorized")
  end

  test "the recipient sees each status; reading creates and changes nothing", ctx do
    email = address("states")
    user = email_user!(email)
    %{invitation_id: id} = invite_member!(ctx.owner, ctx.gym.id, email)
    token = member_token_for(email)

    assert %{
             "status" => "pending",
             "sent_to" => ^email,
             "gym" => %{"gym_id" => gym_id, "name" => "Simple Boxing Gym"},
             "gym_member_id" => nil
           } = user |> resolve(token) |> invitation()

    assert gym_id == ctx.gym.id
    assert member_rows(ctx.gym.id, user) == []
    assert Repo.get!(MemberInvitation, id).status == :pending

    {:ok, accepted} =
      Gyms.accept_member_invitation(user, live_session!(user), {:token, token}, client_ip())

    assert %{"status" => "accepted", "gym_member_id" => member} =
             user |> resolve(token) |> invitation()

    assert member == accepted.gym_member_id
    assert [%Member{status: :active}] = member_rows(ctx.gym.id, user)
  end

  test "declined, cancelled and expired are told apart for the recipient only", ctx do
    other = email_user!(address("other"))

    for {status, finish} <- [
          {"declined",
           fn user, _id, token ->
             {:ok, _} = Gyms.decline_member_invitation(user, {:token, token}, client_ip())
           end},
          {"cancelled",
           fn _user, id, _token ->
             {:ok, _} = Gyms.cancel_member_invitation(ctx.owner, ctx.gym.id, id)
           end},
          {"expired", fn _user, id, _token -> expire!(id) end}
        ] do
      email = address(status)
      user = email_user!(email)
      %{invitation_id: id} = invite_member!(ctx.owner, ctx.gym.id, email)
      token = member_token_for(email)
      finish.(user, id, token)

      assert %{"status" => ^status} = user |> resolve(token) |> invitation()
      # Anyone else learns nothing: the same answer as an unknown token.
      other |> resolve(token) |> error(410, "invitation_unavailable")

      assert {:error, :invitation_unavailable} =
               Gyms.preview_member_invitation(token, client_ip())
    end
  end

  test "another account: mismatch while current, nothing about the invitation", ctx do
    email = address("invited")
    other = email_user!(address("someone"))
    invite_member!(ctx.owner, ctx.gym.id, email)

    refusal =
      other |> resolve(member_token_for(email)) |> error(403, "invitation_recipient_mismatch")

    refute inspect(refusal) =~ email
    refute inspect(refusal) =~ ctx.gym.id
    assert member_rows(ctx.gym.id, other) == []
  end

  test "an unknown, malformed or another domain's token answers the same", ctx do
    user = email_user!(address("unknown"))
    staff_email = address("staff")
    invite!(ctx.owner, ctx.gym.id, staff_email, :coach)

    for token <- [
          "sgm_" <> String.duplicate("a", 43),
          "not-a-token",
          nil,
          staff_token_for(staff_email)
        ] do
      user |> resolve(token) |> error(410, "invitation_unavailable")
    end
  end

  test "the token never reaches the logs", ctx do
    email = address("logs")
    user = email_user!(email)
    invite_member!(ctx.owner, ctx.gym.id, email)
    token = member_token_for(email)

    log = capture_log(fn -> user |> resolve(token) |> invitation() end)
    refute log =~ token
  end
end
