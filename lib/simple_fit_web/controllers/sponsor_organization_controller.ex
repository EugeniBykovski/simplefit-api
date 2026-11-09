defmodule SimpleFitWeb.SponsorOrganizationController do
  @moduledoc """
  The viewer's sponsor organizations (SF-112, ADR 0030). Read-only: organizations
  and memberships are created only by internal provisioning, never here. Every
  organization route is authorized by the viewer's active membership of that
  organization in `SimpleFit.Sponsors`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Sponsors"]

  @security [%{"bearerAuth" => []}]
  @sponsor_id [
    sponsor_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
  ]

  @access """
  * `not_found` - the viewer isn't an active member of this organization, or it doesn't exist or is closed
    (indistinguishable).
  """

  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  operation :index,
    operation_id: "listMySponsorOrganizations",
    summary: "My sponsor organizations",
    description: """
    The viewer's active memberships of sponsor organizations that aren't closed, with each organization and the
    viewer's role. Empty for anyone without one: registration intent, a sponsor application, a contact entry, a
    gym role or operator authority never adds one.
    """,
    security: @security,
    responses:
      [
        ok: {"Organizations", "application/json", Schemas.SponsorOrganizationListResponse}
      ] ++ @base

  def index(conn, _params) do
    render(conn, :index, organizations: Sponsors.list_my_organizations(conn.assigns.current_user))
  end

  operation :show,
    operation_id: "getSponsorOrganization",
    summary: "A sponsor organization",
    description:
      "The organization, the viewer's membership and its permissions (display only).\n\n" <>
        @access,
    security: @security,
    parameters: @sponsor_id,
    responses:
      [
        ok: {"Organization", "application/json", Schemas.SponsorOrganizationResponse},
        not_found: ApiSpec.error_response("not_found")
      ] ++ @base

  def show(conn, %{"sponsor_id" => id}) do
    with {:ok, access} <- Sponsors.get_organization(conn.assigns.current_user, id) do
      render(conn, :show, access: access)
    end
  end

  operation :members,
    operation_id: "listSponsorMembers",
    summary: "Members of a sponsor organization",
    description:
      "Active and suspended members, oldest first; short account names only. `limit` 1..100 (default 50), " <>
        "`cursor` from the previous page.\n\n" <>
        @access <>
        "* `validation_error` - `limit` out of range or a malformed `cursor`.\n",
    security: @security,
    parameters:
      @sponsor_id ++
        [
          limit: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 1, maximum: 100},
            required: false
          ],
          cursor: [in: :query, schema: %Schema{type: :string}, required: false]
        ],
    responses:
      [
        ok: {"Members", "application/json", Schemas.SponsorMemberListResponse},
        not_found: ApiSpec.error_response("not_found"),
        unprocessable_entity: ApiSpec.error_response("validation_error")
      ] ++ @base

  def members(conn, %{"sponsor_id" => id} = params) do
    with {:ok, page} <- Sponsors.list_members(conn.assigns.current_user, id, params) do
      render(conn, :members, page: page)
    end
  end

  operation :contacts,
    operation_id: "listSponsorContacts",
    summary: "Business contacts of a sponsor organization",
    description:
      "The organization's business contacts, primary first. Owner and manager only. A contact is not an " <>
        "account or a member and grants nothing.\n\n" <>
        @access <>
        "* `forbidden` - the viewer's role can't see contacts.\n",
    security: @security,
    parameters: @sponsor_id,
    responses:
      [
        ok: {"Contacts", "application/json", Schemas.SponsorContactListResponse},
        forbidden: ApiSpec.error_response("forbidden"),
        not_found: ApiSpec.error_response("not_found")
      ] ++ @base

  def contacts(conn, %{"sponsor_id" => id}) do
    with {:ok, contacts} <- Sponsors.list_contacts(conn.assigns.current_user, id) do
      render(conn, :contacts, contacts: contacts)
    end
  end
end
