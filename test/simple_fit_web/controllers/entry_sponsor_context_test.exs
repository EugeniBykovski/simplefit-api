defmodule SimpleFitWeb.EntrySponsorContextTest do
  @moduledoc """
  SF-117 over HTTP (in-process endpoint, PostgreSQL in the SQL sandbox): the
  canonical entry answer for every sponsor application state, approved
  organizations, several organizations, and what a stale context (a remembered
  choice, a requested `sponsor_id`, an old session) can and can't do once access
  changes. Entry is a routing projection; each organization request authorizes
  its own path, so both are checked together. Responses are checked against
  OpenAPI.
  """

  use SimpleFitWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.SponsorHelpers
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, completed_gym!: 1]
  import SimpleFit.FighterOnboardingHelpers, only: [complete_fighter_onboarding!: 1]

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Sponsors.{Membership, Organization, Provisioning}
  alias SimpleFitWeb.ApiSpec

  defp token!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp call(method, path, token, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    case method do
      :get ->
        get(conn, path)

      :post ->
        post(conn, path)

      :put ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put(path, Jason.encode!(body))
    end
  end

  defp entry(token, query \\ "") do
    body = call(:get, "/api/v1/me/entry" <> query, token) |> json_response(200)
    assert_schema(body, "EntryResponse", ApiSpec.spec())
    body["entry"]
  end

  defp organization(token, id), do: call(:get, "/api/v1/sponsor-organizations/#{id}", token)

  defp choose(token, id),
    do:
      call(:put, "/api/v1/me/entry/context", token, %{"context" => "sponsor", "sponsor_id" => id})

  defp suspend!(org),
    do:
      {:ok, _} = Provisioning.suspend_organization(fixture_authority(), org.id, "policy_concern")

  defp reinstate!(org),
    do:
      {:ok, _} =
        Provisioning.reinstate_organization(fixture_authority(), org.id, "concern_resolved")

  defp revoke!(%Membership{id: id}),
    do: {:ok, _} = Provisioning.revoke_membership(fixture_authority(), id, "left_company")

  describe "application states with a sponsor intent (no organization)" do
    test "none, draft, submitted, under review, changes requested: never a workspace" do
      user = registered!("applicant")
      token = token!(user)

      assert %{"destination" => "sponsor_application", "capabilities" => []} =
               entry(token, "?intent=sponsor")

      application = draft!(user)

      assert %{"destination" => "sponsor_application_draft", "sponsor_id" => nil} =
               entry(token, "?intent=sponsor")

      submitted = submitted!(user, application)

      assert %{
               "destination" => "sponsor_application_status",
               "reason" => "sponsor_application_submitted"
             } = entry(token, "?intent=sponsor")

      review!(submitted, :under_review)

      assert %{"reason" => "sponsor_application_under_review", "capabilities" => []} =
               entry(token, "?intent=sponsor")

      review!(submitted, :changes_requested)

      assert %{
               "destination" => "sponsor_application_status",
               "reason" => "sponsor_application_changes_requested",
               "sponsor_workspaces" => []
             } = entry(token, "?intent=sponsor")

      # An applicant reads no organization and holds none.
      assert call(:get, "/api/v1/me/sponsor-organizations", token)
             |> json_response(200) == %{"organizations" => []}

      assert Repo.aggregate(Organization, :count) == 0
    end

    test "an approved application without an organization opens its status, never a workspace" do
      user = registered!("approved-only")
      token = token!(user)

      user
      |> draft!()
      |> then(&submitted!(user, &1))
      |> review!(:under_review)
      |> review!(:approved)

      assert %{
               "destination" => "sponsor_application_status",
               "reason" => "sponsor_application_closed",
               "capabilities" => [],
               "sponsor_id" => nil,
               "sponsor_workspace_count" => 0
             } = entry(token, "?intent=sponsor")

      # Without intent the user has nothing completed: still no workspace.
      refute entry(token)["destination"] == "sponsor_home"
    end
  end

  describe "an approved organization" do
    setup do
      owner = registered!("owner")
      %{organization: org, owner: m} = provision!(owner)
      %{owner: owner, org: org, membership: m, token: token!(owner)}
    end

    test "opens its home; the organization reads; nothing else is lost", c do
      complete_fighter_onboarding!(c.owner)

      assert %{
               "destination" => "sponsor_home",
               "reason" => "sponsor_workspace_active",
               "sponsor_id" => id,
               "capabilities" => caps
             } = entry(c.token, "?intent=sponsor")

      assert id == c.org.id
      assert Enum.sort(caps) == ["FIGHTER", "SPONSOR_WORKSPACE"]

      # Without intent, two completed contexts: the user chooses; both are offered.
      assert %{"destination" => "context_selection", "sponsor_workspaces" => [ws]} =
               entry(c.token)

      assert ws["sponsor_id"] == c.org.id and ws["selected"] == false

      body = organization(c.token, c.org.id) |> json_response(200)
      assert_schema(body, "SponsorOrganizationResponse", ApiSpec.spec())
      assert body["organization"]["status"] == "active"
    end

    test "suspension: read-only details, but no workspace, no choice and no stale context", c do
      complete_fighter_onboarding!(c.owner)
      assert choose(c.token, c.org.id) |> response(204)
      assert %{"destination" => "sponsor_home", "reason" => "last_context"} = entry(c.token)

      suspend!(c.org)

      # The remembered choice and an explicit context are both ignored now.
      assert %{
               "destination" => "fighter_home",
               "capabilities" => ["FIGHTER"],
               "sponsor_workspaces" => []
             } = entry(c.token)

      assert %{"context" => nil, "sponsor_id" => nil} =
               entry(c.token, "?context=sponsor&sponsor_id=#{c.org.id}")

      assert %{"destination" => "sponsor_application"} = entry(c.token, "?intent=sponsor")
      assert choose(c.token, c.org.id) |> json_response(404)

      # The approved policy (ADR 0030, ADR 0033): a suspended organization stays
      # readable by its members, as suspended.
      assert organization(c.token, c.org.id)
             |> json_response(200)
             |> get_in(~w(organization status)) ==
               "suspended"

      reinstate!(c.org)
      assert %{"destination" => "sponsor_home", "reason" => "last_context"} = entry(c.token)
    end

    test "revocation: the next request with the same session is denied everywhere", c do
      member = registered!("member")
      membership = member!(c.org, member)
      token = token!(member)

      assert choose(token, c.org.id) |> response(204)
      assert %{"destination" => "sponsor_home"} = entry(token)
      assert organization(token, c.org.id) |> json_response(200)

      revoke!(membership)

      assert organization(token, c.org.id) |> json_response(404)

      assert call(:get, "/api/v1/sponsor-organizations/#{c.org.id}/members", token)
             |> json_response(404)

      assert %{"capabilities" => [], "sponsor_workspaces" => [], "sponsor_id" => nil} =
               entry(token)

      assert %{"context" => nil} = entry(token, "?context=sponsor&sponsor_id=#{c.org.id}")
      assert choose(token, c.org.id) |> json_response(404)

      # The stale row stays a preference that is never honoured (re-validated on read).
      assert Repo.one!(from(x in ContextChoice, where: x.user_id == ^member.id)).sponsor_organization_id ==
               c.org.id
    end

    test "forged, foreign and malformed ids get the same not_found; a request names nothing", c do
      stranger = registered!("stranger")
      %{organization: theirs} = provision!(stranger)
      token = c.token

      for id <- [theirs.id, Ecto.UUID.generate()] do
        assert %{"error" => %{"code" => "not_found"}} =
                 organization(token, id) |> json_response(404)

        assert choose(token, id) |> json_response(404)
        # Ignored, never reported: the answer is the viewer's own workspace.
        assert %{"context" => nil, "sponsor_id" => own} =
                 entry(token, "?context=sponsor&sponsor_id=#{id}")

        assert own == c.org.id
      end

      assert organization(token, "not-a-uuid") |> json_response(404)

      assert %{"error" => %{"code" => "validation_error"}} =
               call(:get, "/api/v1/me/entry?context=sponsor&sponsor_id=not-a-uuid", token)
               |> json_response(422)
    end

    test "logout ends the session: the old token reads nothing", c do
      assert organization(c.token, c.org.id) |> json_response(200)
      assert call(:post, "/api/auth/logout", c.token) |> response(204)

      assert organization(c.token, c.org.id) |> json_response(401)
      assert call(:get, "/api/v1/me/entry", c.token) |> json_response(401)
    end

    test "anonymous and invalid sessions are 401", c do
      assert build_conn() |> get("/api/v1/me/entry") |> json_response(401)

      assert build_conn()
             |> get("/api/v1/sponsor-organizations/#{c.org.id}")
             |> json_response(401)

      assert organization("sfa_invalid", c.org.id) |> json_response(401)
    end
  end

  describe "several organizations" do
    test "both are choices; a choice selects, never grants; data stays per organization" do
      user = registered!("agency")
      other = registered!("other-owner")
      %{organization: own} = provision!(user, %{display_name: "Own Org"})
      %{organization: joined} = provision!(other, %{display_name: "Joined Org"})
      _ = member!(joined, user)
      token = token!(user)

      assert %{
               "destination" => "context_selection",
               "reason" => "sponsor_choice_required",
               "sponsor_workspace_count" => 2,
               "sponsor_workspaces" => workspaces
             } = entry(token, "?intent=sponsor")

      assert Enum.map(workspaces, &{&1["sponsor_id"], &1["role"], &1["selected"]}) == [
               {own.id, "owner", false},
               {joined.id, "member", false}
             ]

      assert choose(token, joined.id) |> response(204)

      assert %{"destination" => "sponsor_home", "sponsor_id" => id, "reason" => "last_context"} =
               entry(token, "?intent=sponsor")

      assert id == joined.id

      # The choice changed nothing about permissions: still a member there.
      assert organization(token, joined.id) |> json_response(200) |> get_in(~w(membership role)) ==
               "member"

      assert call(:get, "/api/v1/sponsor-organizations/#{joined.id}/contacts", token)
             |> json_response(403)

      # Each organization answers for itself.
      assert organization(token, own.id)
             |> json_response(200)
             |> get_in(~w(organization sponsor_id)) ==
               own.id

      # Suspending the chosen one falls back to the other: the only one left.
      suspend!(joined)

      own_id = own.id

      assert %{"destination" => "sponsor_home", "sponsor_id" => ^own_id} =
               entry(token, "?intent=sponsor")
    end

    test "mixed contexts: gym staff, fighter and sponsor stay independent" do
      user = registered!("mixed")
      complete_fighter_onboarding!(user)
      gym = completed_gym!(user)
      %{organization: org} = provision!(user)
      token = token!(user)

      e = entry(token)
      assert e["destination"] == "context_selection"
      assert Enum.sort(e["capabilities"]) == ["FIGHTER", "GYM_WORKSPACE", "SPONSOR_WORKSPACE"]
      assert [%{"gym_id" => gym_id}] = e["gym_workspaces"]
      assert gym_id == gym.id
      assert [%{"sponsor_id" => sponsor_id}] = e["sponsor_workspaces"]
      assert sponsor_id == org.id

      assert %{"destination" => "sponsor_home", "context" => "sponsor"} =
               entry(token, "?context=sponsor&sponsor_id=#{org.id}")

      assert %{"destination" => "gym_home", "context" => "gym"} =
               entry(token, "?context=gym&gym_id=#{gym.id}")
    end
  end

  test "one user's organization never appears for another account" do
    a = registered!("account-a")
    b = registered!("account-b")
    %{organization: org} = provision!(a)
    b_token = token!(b)

    assert %{"sponsor_workspaces" => [], "capabilities" => []} = entry(b_token, "?intent=sponsor")
    assert organization(b_token, org.id) |> json_response(404)
    assert choose(b_token, org.id) |> json_response(404)

    assert call(:get, "/api/v1/me/sponsor-organizations", b_token) |> json_response(200) ==
             %{"organizations" => []}
  end
end
