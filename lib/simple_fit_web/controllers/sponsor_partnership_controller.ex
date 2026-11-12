defmodule SimpleFitWeb.SponsorPartnershipController do
  @moduledoc """
  A sponsor organization's partnership preferences, opportunities and nonbinding
  partnership proposals (SF-130, ADR 0034). Every organization route is authorized by
  the viewer's active membership in `SimpleFit.Sponsors.Partnerships`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.{Partnerships, Proposal}
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.SponsorPartnershipJSON

  tags ["Sponsors"]

  @security [%{"bearerAuth" => []}]
  @sponsor_id [
    sponsor_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
  ]
  @proposal_id @sponsor_id ++
                 [
                   proposal_id: [
                     in: :path,
                     schema: %Schema{type: :string, format: :uuid},
                     required: true
                   ]
                 ]

  @access """
  * `not_found` - the viewer isn't an active member of this organization, or it doesn't exist or is closed, or
    the proposal isn't this organization's (indistinguishable).
  """

  @write """
  Needs the owner or a manager (`manage_partnerships`) of an active organization.
  * `forbidden` - a member without that permission.
  * `conflict` - `details.organization: "suspended"` (read-only), or as described.
  * `revision_conflict` - stale `expected_revision` (`details.current_revision`).
  * `rate_limited` - too many writes.
  """

  @read_base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @write_base @read_base ++
                [
                  forbidden: ApiSpec.error_response("forbidden"),
                  conflict: ApiSpec.error_response("conflict"),
                  unprocessable_entity: ApiSpec.error_response("validation_error"),
                  too_many_requests: ApiSpec.error_response("rate_limited")
                ]

  @proposal_ok {"The proposal", "application/json", Schemas.SponsorPartnershipProposalResponse}

  operation :policy,
    operation_id: "getSponsorPartnershipPolicy",
    summary: "The partnership preferences and proposal policy",
    description:
      "Vocabularies, requiredness, the open proposal limit and the statuses (D-SA37). No budget is collected.",
    security: @security,
    responses: [
      ok: {"Policy", "application/json", Schemas.SponsorPartnershipPolicyResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def policy(conn, _params), do: render(conn, :policy, policy: Partnerships.policy())

  operation :opportunities,
    operation_id: "listSponsorPartnershipOpportunities",
    summary: "Partnership opportunities of a sponsor organization",
    description:
      """
      No opportunity inventory exists and none is invented (D-SA21): the answer is always `unavailable` with reason
      `no_inventory`. Any member may read it.

      """ <> @access,
    security: @security,
    parameters: @sponsor_id,
    responses:
      [ok: {"Availability", "application/json", Schemas.SponsorPartnershipOpportunitiesResponse}] ++
        @read_base

  def opportunities(conn, %{"sponsor_id" => id}) do
    with {:ok, result} <- Partnerships.opportunities(user(conn), id) do
      render(conn, :opportunities, result: result)
    end
  end

  operation :show_preferences,
    operation_id: "getSponsorPartnershipPreferences",
    summary: "Partnership preferences of a sponsor organization",
    description:
      """
      The organization's current interests, markets and goals (`null` until first saved), beside what its
      application last submitted (read-only, never changed). Any member may read them.

      """ <> @access,
    security: @security,
    parameters: @sponsor_id,
    responses:
      [
        ok: {"Preferences", "application/json", Schemas.SponsorPartnershipPreferencesResponse}
      ] ++ @read_base

  def show_preferences(conn, %{"sponsor_id" => id}) do
    with {:ok, view} <- Partnerships.get_preferences(user(conn), id) do
      render(conn, :preferences, view: view)
    end
  end

  operation :update_preferences,
    operation_id: "updateSponsorPartnershipPreferences",
    summary: "Save partnership preferences",
    description:
      """
      Only the sent fields change, each validated now; an invalid save changes nothing. `expected_revision: 0`
      creates the preferences; afterwards name the current revision. The application's submitted answers are
      never changed.

      """ <> @write <> @access,
    security: @security,
    parameters: @sponsor_id,
    request_body:
      {"Preferences", "application/json", Schemas.UpdateSponsorPartnershipPreferencesRequest,
       required: true},
    responses:
      [
        ok: {"Preferences", "application/json", Schemas.SponsorPartnershipPreferencesResponse}
      ] ++ @write_base

  def update_preferences(conn, %{"sponsor_id" => id} = params) do
    with {:ok, view} <- Partnerships.save_preferences(user(conn), id, body(params), ctx()) do
      render(conn, :preferences, view: view)
    end
  end

  operation :index,
    operation_id: "listSponsorPartnershipProposals",
    summary: "Partnership proposals of a sponsor organization",
    description:
      """
      Newest first. `status` filters by one status; `limit` 1..100 (default 50); `cursor` from the previous page.
      Any member may read them.

      """ <> @access <> "* `validation_error` - a bad `status`, `limit` or `cursor`.\n",
    security: @security,
    parameters:
      @sponsor_id ++
        [
          status: [
            in: :query,
            schema: %Schema{
              type: :string,
              enum: Enum.map(Proposal.statuses(), &Atom.to_string/1)
            }
          ],
          limit: [in: :query, schema: %Schema{type: :integer, minimum: 1, maximum: 100}],
          cursor: [in: :query, schema: %Schema{type: :string, maxLength: 200}]
        ],
    responses:
      [
        ok: {"Proposals", "application/json", Schemas.SponsorPartnershipProposalListResponse},
        unprocessable_entity: ApiSpec.error_response("validation_error")
      ] ++ @read_base

  def index(conn, %{"sponsor_id" => id} = params) do
    with {:ok, page} <- Partnerships.list_proposals(user(conn), id, params) do
      render(conn, :index, page: page)
    end
  end

  operation :create,
    operation_id: "createSponsorPartnershipProposal",
    summary: "Start a partnership proposal",
    description:
      """
      A new draft general inquiry (no opportunity: none exists). A repeat with the same `client_request_id` and
      answers returns the same draft; the key with other answers is `conflict` (`details.client_request_id:
      "reused"`). `conflict` with `details.proposals: "open_limit"` at the open proposal limit. Nonbinding:
      creates nothing commercial.

      """ <> @write <> @access,
    security: @security,
    parameters: @sponsor_id,
    request_body:
      {"Proposal", "application/json", Schemas.CreateSponsorPartnershipProposalRequest,
       required: true},
    responses: [created: @proposal_ok] ++ @write_base

  def create(conn, %{"sponsor_id" => id} = params) do
    with {:ok, view} <- Partnerships.create_proposal(user(conn), id, body(params), ctx()) do
      conn |> put_status(:created) |> render(:show, view: view)
    end
  end

  operation :show,
    operation_id: "getSponsorPartnershipProposal",
    summary: "A partnership proposal",
    description:
      """
      The proposal's answers, status, what a submission still needs, the actions open to the viewer (display
      only), the open change request, its submissions and status history. Any member may read it.

      """ <> @access,
    security: @security,
    parameters: @proposal_id,
    responses: [ok: @proposal_ok] ++ @read_base

  def show(conn, %{"sponsor_id" => id, "proposal_id" => proposal_id}) do
    with {:ok, view} <- Partnerships.get_proposal(user(conn), id, proposal_id) do
      render(conn, :show, view: view)
    end
  end

  operation :update,
    operation_id: "updateSponsorPartnershipProposal",
    summary: "Save a partnership proposal",
    description:
      """
      A draft or a proposal with changes requested. Only the sent answers change; after a change request only
      the answers it names (`validation_error` with `not_requested`). `conflict` with `details.proposal:
      "not_editable"` in another status.

      """ <> @write <> @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Answers", "application/json", Schemas.UpdateSponsorPartnershipProposalRequest,
       required: true},
    responses: [ok: @proposal_ok] ++ @write_base

  def update(conn, %{"sponsor_id" => id, "proposal_id" => proposal_id} = params) do
    with {:ok, view} <-
           Partnerships.update_proposal(user(conn), id, proposal_id, body(params), ctx()) do
      render(conn, :show, view: view)
    end
  end

  operation :submit,
    operation_id: "submitSponsorPartnershipProposal",
    summary: "Submit a partnership proposal",
    description:
      """
      `draft` or `changes_requested` -> `submitted`, with an immutable snapshot of the answers. A repeat of the
      same request answers the same and changes nothing; the key for another request is `conflict`
      (`details.client_request_id: "reused"`). `validation_error` naming each missing answer (`required`).
      `conflict` with `details.proposal: "not_submittable"` in another status. Nonbinding; no email is sent.

      """ <> @write <> @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Submit", "application/json", Schemas.SponsorPartnershipProposalCommandRequest,
       required: true},
    responses: [ok: @proposal_ok] ++ @write_base

  def submit(conn, %{"sponsor_id" => id, "proposal_id" => proposal_id} = params) do
    with {:ok, view} <-
           Partnerships.submit_proposal(user(conn), id, proposal_id, body(params), ctx()) do
      render(conn, :show, view: view)
    end
  end

  operation :withdraw,
    operation_id: "withdrawSponsorPartnershipProposal",
    summary: "Withdraw a partnership proposal",
    description:
      """
      Any open proposal (`draft`, `submitted`, `under_review`, `changes_requested`) -> `withdrawn`, final. A
      repeat of the same withdrawal answers the same. `conflict` with `details.proposal: "not_withdrawable"` once
      decided or withdrawn.

      """ <> @write <> @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Withdraw", "application/json", Schemas.SponsorPartnershipProposalCommandRequest,
       required: true},
    responses: [ok: @proposal_ok] ++ @write_base

  def withdraw(conn, %{"sponsor_id" => id, "proposal_id" => proposal_id} = params) do
    with {:ok, view} <-
           Partnerships.withdraw_proposal(user(conn), id, proposal_id, body(params), ctx()) do
      render(conn, :show, view: view)
    end
  end

  defp body(params), do: Map.drop(params, ["sponsor_id", "proposal_id", "format"])
  defp user(conn), do: conn.assigns.current_user
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
