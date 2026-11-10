defmodule SimpleFitWeb.SponsorFirstRunControllerTest do
  @moduledoc """
  SF-119 over HTTP (in-process endpoint, PostgreSQL in the SQL sandbox): the partner
  portal first run per organization and member. Responses are checked against
  OpenAPI.
  """

  use SimpleFitWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Sponsors.{Membership, Provisioning, SponsorFirstRun}
  alias SimpleFitWeb.ApiSpec

  defp token!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp call(method, path, token, body \\ %{}) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    case method do
      :get ->
        get(conn, path)

      :post ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(body))
    end
  end

  defp run_path(org, suffix \\ ""),
    do: "/api/v1/sponsor-organizations/#{org.id}/first-run#{suffix}"

  defp first_run!(conn, status \\ 200) do
    body = json_response(conn, status)
    assert_schema(body, "SponsorFirstRunResponse", ApiSpec.spec())
    body["first_run"]
  end

  setup do
    owner = registered!("owner")
    %{organization: org} = provision!(owner)
    %{owner: owner, org: org, token: token!(owner)}
  end

  test "not started, then started, then completed: final and idempotent", c do
    assert %{"status" => "not_started", "started_at" => nil} =
             call(:get, run_path(c.org), c.token) |> first_run!()

    assert Repo.aggregate(SponsorFirstRun, :count) == 0

    started = call(:post, run_path(c.org, "/start"), c.token) |> first_run!()
    assert started["status"] == "in_progress"
    # Repeating the start keeps the first one.
    assert call(:post, run_path(c.org, "/start"), c.token) |> first_run!() == started

    done = call(:post, run_path(c.org, "/complete"), c.token) |> first_run!()
    assert done["status"] == "completed" and done["completed_at"] >= started["started_at"]
    assert call(:post, run_path(c.org, "/complete"), c.token) |> first_run!() == done

    # The other outcome is a conflict naming the kept one; nothing changes.
    assert %{"error" => %{"code" => "conflict", "details" => %{"first_run" => "completed"}}} =
             call(:post, run_path(c.org, "/dismiss"), c.token) |> json_response(409)

    assert %{"error" => %{"details" => %{"first_run" => "completed"}}} =
             call(:post, run_path(c.org, "/start"), c.token) |> json_response(409)

    assert call(:get, run_path(c.org), c.token) |> first_run!() == done
    assert Repo.aggregate(SponsorFirstRun, :count) == 1
  end

  test "dismissed without starting is final; a later completion is a conflict", c do
    assert %{"status" => "dismissed", "started_at" => nil} =
             call(:post, run_path(c.org, "/dismiss"), c.token) |> first_run!()

    assert %{"error" => %{"details" => %{"first_run" => "dismissed"}}} =
             call(:post, run_path(c.org, "/complete"), c.token) |> json_response(409)
  end

  test "per organization and member: another organization or member starts fresh", c do
    member = registered!("member")
    _ = member!(c.org, member)
    %{organization: other} = provision!(registered!("other-owner"))
    _ = member!(other, c.owner)

    call(:post, run_path(c.org, "/complete"), c.token) |> first_run!()

    assert %{"status" => "not_started"} = call(:get, run_path(other), c.token) |> first_run!()

    member_token = token!(member)
    # Any role has the introduction.
    assert %{"status" => "not_started"} =
             call(:get, run_path(c.org), member_token) |> first_run!()

    assert %{"status" => "completed"} = call(:get, run_path(c.org), c.token) |> first_run!()
  end

  test "strangers, forged and malformed ids, revoked members and anonymous get nothing", c do
    stranger = token!(registered!("stranger"))

    for p <- [run_path(c.org), run_path(c.org, "/complete")] do
      method = if String.ends_with?(p, "first-run"), do: :get, else: :post

      assert %{"error" => %{"code" => "not_found"}} =
               call(method, p, stranger) |> json_response(404)
    end

    forged = "/api/v1/sponsor-organizations/#{Ecto.UUID.generate()}/first-run"
    assert call(:get, forged, c.token) |> json_response(404)

    assert call(:get, "/api/v1/sponsor-organizations/not-a-uuid/first-run", c.token)
           |> json_response(404)

    assert build_conn() |> get(run_path(c.org)) |> json_response(401)

    member = registered!("revoked")
    membership = member!(c.org, member)
    member_token = token!(member)
    {:ok, _} = Provisioning.revoke_membership(fixture_authority(), membership.id, "left")
    assert call(:post, run_path(c.org, "/complete"), member_token) |> json_response(404)
    assert Repo.aggregate(from(r in SponsorFirstRun, where: r.user_id == ^member.id), :count) == 0
  end

  test "a suspended organization is unavailable, refuses transitions, and keeps a final outcome",
       c do
    member = registered!("member")
    _ = member!(c.org, member)
    member_token = token!(member)
    call(:post, run_path(c.org, "/complete"), c.token) |> first_run!()

    {:ok, _} = Provisioning.suspend_organization(fixture_authority(), c.org.id, "policy_concern")

    assert %{"status" => "unavailable"} =
             call(:get, run_path(c.org), member_token) |> first_run!()

    assert %{
             "error" => %{
               "code" => "conflict",
               "details" => %{"organization_status" => "suspended"}
             }
           } =
             call(:post, run_path(c.org, "/start"), member_token) |> json_response(409)

    assert %{"status" => "completed"} = call(:get, run_path(c.org), c.token) |> first_run!()

    {:ok, _} = Provisioning.reinstate_organization(fixture_authority(), c.org.id, "resolved")

    assert %{"status" => "not_started"} =
             call(:get, run_path(c.org), member_token) |> first_run!()
  end

  test "a body is refused: no user, step or organization can be named", c do
    assert %{"error" => %{"code" => "validation_error", "details" => %{"fields" => fields}}} =
             call(:post, run_path(c.org, "/complete"), c.token, %{
               "user_id" => Ecto.UUID.generate(),
               "step" => 3
             })
             |> json_response(422)

    assert fields |> Map.keys() |> Enum.sort() == ["step", "user_id"]
    assert Repo.aggregate(SponsorFirstRun, :count) == 0
  end

  test "the first run grants nothing: the membership and organization are unchanged", c do
    before = Repo.all(Membership)
    call(:post, run_path(c.org, "/complete"), c.token) |> first_run!()
    assert Repo.all(Membership) == before
    assert Repo.reload!(c.org).status == :active
  end
end
