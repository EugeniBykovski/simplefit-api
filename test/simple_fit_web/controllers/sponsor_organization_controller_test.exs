defmodule SimpleFitWeb.SponsorOrganizationControllerTest do
  @moduledoc """
  SF-112 over HTTP: the read-only sponsor organization API, its concealment, and
  sponsor workspaces in the entry API. Responses are checked against OpenAPI.
  """

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.Accounts
  alias SimpleFit.Sponsors.Provisioning
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

      :put ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put(path, Jason.encode!(body))
    end
  end

  setup do
    owner = registered!("owner")
    member = registered!("member")
    %{organization: org} = provision!(owner)
    m = member!(org, member)
    %{owner: owner, member: member, org: org, membership: m}
  end

  test "members read their organization; contacts are for owner and manager", c do
    owner_token = token!(c.owner)
    member_token = token!(c.member)

    list = call(:get, "/api/v1/me/sponsor-organizations", member_token) |> json_response(200)
    assert_schema(list, "SponsorOrganizationListResponse", ApiSpec.spec())

    assert [%{"organization" => %{"sponsor_id" => id}, "membership" => %{"role" => "member"}}] =
             list["organizations"]

    assert id == c.org.id

    show =
      call(:get, "/api/v1/sponsor-organizations/#{c.org.id}", member_token) |> json_response(200)

    assert_schema(show, "SponsorOrganizationResponse", ApiSpec.spec())
    assert show["membership"]["permissions"] == ["view_organization", "view_members"]
    refute Map.has_key?(show["organization"], "provisioning_source")

    members =
      call(:get, "/api/v1/sponsor-organizations/#{c.org.id}/members", member_token)
      |> json_response(200)

    assert_schema(members, "SponsorMemberListResponse", ApiSpec.spec())
    refute Jason.encode!(members) =~ "@"

    assert %{"error" => %{"code" => "forbidden"}} =
             call(:get, "/api/v1/sponsor-organizations/#{c.org.id}/contacts", member_token)
             |> json_response(403)

    contacts =
      call(:get, "/api/v1/sponsor-organizations/#{c.org.id}/contacts", owner_token)
      |> json_response(200)

    assert_schema(contacts, "SponsorContactListResponse", ApiSpec.spec())
    assert [%{"kind" => "primary"}] = contacts["contacts"]
  end

  test "everyone else gets the same not_found; no session is 401", c do
    outsider = token!(registered!("outsider"))

    bodies =
      for path <- [
            "/api/v1/sponsor-organizations/#{c.org.id}",
            "/api/v1/sponsor-organizations/#{c.org.id}/members",
            "/api/v1/sponsor-organizations/#{c.org.id}/contacts",
            "/api/v1/sponsor-organizations/#{Ecto.UUID.generate()}",
            "/api/v1/sponsor-organizations/not-a-uuid"
          ] do
        body = call(:get, path, outsider) |> json_response(404)
        assert_schema(body, "ErrorResponse", ApiSpec.spec())
        Map.delete(body["error"], "request_id")
      end

    assert length(Enum.uniq(bodies)) == 1

    assert %{"organizations" => []} =
             call(:get, "/api/v1/me/sponsor-organizations", outsider) |> json_response(200)

    assert build_conn() |> get("/api/v1/me/sponsor-organizations") |> json_response(401)
  end

  test "revocation takes effect on the next request with the same session", c do
    token = token!(c.member)
    assert call(:get, "/api/v1/sponsor-organizations/#{c.org.id}", token) |> json_response(200)

    {:ok, _} =
      Provisioning.revoke_membership(fixture_authority(), c.membership.id, "left_company")

    assert call(:get, "/api/v1/sponsor-organizations/#{c.org.id}", token) |> json_response(404)
  end

  test "entry: sponsor intent, workspace home and a remembered sponsor context", c do
    token = token!(c.member)

    entry = call(:get, "/api/v1/me/entry?intent=sponsor", token) |> json_response(200)
    assert_schema(entry, "EntryResponse", ApiSpec.spec())

    assert %{
             "destination" => "sponsor_home",
             "reason" => "sponsor_workspace_active",
             "capabilities" => ["SPONSOR_WORKSPACE"],
             "sponsor_workspace_count" => 1,
             "sponsor_workspaces" => [%{"role" => "member", "selected" => false}]
           } = entry["entry"]

    assert entry["entry"]["sponsor_id"] == c.org.id

    assert call(:put, "/api/v1/me/entry/context", token, %{
             "context" => "sponsor",
             "sponsor_id" => c.org.id
           })
           |> response(204)

    assert %{"error" => %{"code" => "not_found"}} =
             call(:put, "/api/v1/me/entry/context", token, %{
               "context" => "sponsor",
               "sponsor_id" => Ecto.UUID.generate()
             })
             |> json_response(404)

    applicant = token!(registered!("applicant"))

    assert %{
             "entry" => %{
               "destination" => "sponsor_application",
               "sponsor_id" => nil,
               "capabilities" => []
             }
           } =
             call(:get, "/api/v1/me/entry?intent=sponsor", applicant) |> json_response(200)
  end
end
