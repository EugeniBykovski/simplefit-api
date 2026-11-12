defmodule SimpleFitWeb.AdminSponsorProposalController do
  @moduledoc """
  Partnership proposal review for platform operators (SF-130, ADR 0034): the audited
  queue and detail, and declared admin actions through the SF-111 framework (claim,
  request changes, accept, decline). Everything answers `not_found` to an account
  without a usable operator. Nothing here creates anything commercial.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
  alias SimpleFit.Sponsors.ProposalReview
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.AdminSponsorProposalJSON

  tags ["Platform operators"]

  @security [%{"bearerAuth" => []}]
  @proposal_id [
    proposal_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
  ]

  @access """
  * `not_found` - not a usable operator, or no such submitted proposal (drafts are never visible).
  * `enrollment_required`, `forbidden` (permission), `step_up_required` (key check).
  * `conflict` - `details.target: "self"` (the operator belongs to the proposing organization), the proposal's
    status, or `details.organization` when the organization isn't active.
  * `revision_conflict` - the proposal changed since `expected_revision`.
  """

  @ok {"The proposal", "application/json", Schemas.SponsorProposalReviewResponse}

  @confirmed """
  Needs a one-time `confirmation_token` from a preview of exactly this request (same operator, session,
  proposal, revision and reason), with `reason_code`, `expected_revision` and `operation_id` (a repeat of the
  same request returns the current state and changes nothing).
  * `confirmation_required`, `confirmation_invalid` - missing, expired, used or for another request.
  """
  @preview_ok {"Preview", "application/json", Schemas.OperatorActionPreviewResponse}
  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    conflict: ApiSpec.error_response("conflict"),
    unprocessable_entity: ApiSpec.error_response("validation_error"),
    too_many_requests: ApiSpec.error_response("rate_limited"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]
  @confirmed_errors @base ++
                      [precondition_required: ApiSpec.error_response("confirmation_required")]

  operation :index,
    operation_id: "listSponsorProposalsForReview",
    summary: "The partnership proposal review queue",
    description:
      """
      Needs `sponsors.proposals.read` and a key check. Submitted proposals (never drafts), oldest submission
      first, with the organization's name and status and nothing about its people. `limit` 1..100 (default 50);
      `cursor` from the previous page, valid only for the same filter and reader. Each query is audited.

      """ <> @access,
    security: @security,
    parameters: [
      status: [
        in: :query,
        schema: %Schema{
          type: :string,
          enum: Enum.map(ProposalReview.queue_statuses(), &Atom.to_string/1)
        }
      ],
      limit: [in: :query, schema: %Schema{type: :integer, minimum: 1, maximum: 100}],
      cursor: [in: :query, schema: %Schema{type: :string, maxLength: 1024}]
    ],
    responses: [ok: {"A page", "application/json", Schemas.SponsorProposalQueueResponse}] ++ @base

  def index(conn, params) do
    with {:ok, page} <- Operators.list_sponsor_proposals(user(conn), session(conn), params, ctx()) do
      render(conn, :index, page: page)
    end
  end

  operation :show,
    operation_id: "getSponsorProposalForReview",
    summary: "A partnership proposal for review",
    description:
      "Needs `sponsors.proposals.read` and a key check. Exactly what was last submitted. Each view is audited.\n\n" <>
        @access,
    security: @security,
    parameters: @proposal_id,
    responses: [ok: @ok] ++ @base

  def show(conn, %{"proposal_id" => id}) do
    with {:ok, review} <- Operators.get_sponsor_proposal(user(conn), session(conn), id, ctx()) do
      render(conn, :show, review: review)
    end
  end

  operation :preview_claim,
    operation_id: "previewClaimSponsorProposal",
    summary: "Preview claiming a partnership proposal",
    description:
      "Needs `sponsors.proposals.claim` and a fresh key check. Changes nothing.\n\n" <> @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Claim", "application/json", Schemas.ClaimSponsorProposalRequest, required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_claim(conn, %{"proposal_id" => id} = params),
    do: preview(conn, "sponsor_proposal.claim", id, params)

  operation :claim,
    operation_id: "claimSponsorProposal",
    summary: "Claim a partnership proposal for review",
    description:
      "Needs `sponsors.proposals.claim` and a fresh key check: `submitted` -> `under_review`, for an active " <>
        "organization. Takes `reason_code`, `expected_revision` and `operation_id` (a repeat changes nothing).\n\n" <>
        @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Claim", "application/json", Schemas.ClaimSponsorProposalRequest, required: true},
    responses: [ok: @ok] ++ @base

  def claim(conn, %{"proposal_id" => id} = params),
    do: execute(conn, "sponsor_proposal.claim", id, params)

  operation :preview_request_changes,
    operation_id: "previewRequestSponsorProposalChanges",
    summary: "Preview requesting changes to a partnership proposal",
    description:
      "Needs `sponsors.proposals.request_changes` and a fresh key check. Changes nothing.\n\n" <>
        @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Change request", "application/json", Schemas.RequestSponsorProposalChangesRequest,
       required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_request_changes(conn, %{"proposal_id" => id} = params),
    do: preview(conn, "sponsor_proposal.request_changes", id, params)

  operation :request_changes,
    operation_id: "requestSponsorProposalChanges",
    summary: "Request changes to a partnership proposal",
    description:
      """
      Needs `sponsors.proposals.request_changes` and a fresh key check: `under_review` -> `changes_requested`, for
      an active organization, with the answers its members may change and a plain-text message they see (no email
      is sent). The organization's next submission resolves it. Takes `reason_code`, `expected_revision` and
      `operation_id`.

      """ <> @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Change request", "application/json", Schemas.RequestSponsorProposalChangesRequest,
       required: true},
    responses: [ok: @ok] ++ @base

  def request_changes(conn, %{"proposal_id" => id} = params),
    do: execute(conn, "sponsor_proposal.request_changes", id, params)

  operation :preview_accept,
    operation_id: "previewAcceptSponsorProposal",
    summary: "Preview: accept a partnership proposal",
    description:
      "Needs `sponsors.proposals.accept` and a fresh key check. Changes nothing; returns the impact and a one-time confirmation.\n\n" <>
        @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Decision", "application/json", Schemas.AcceptSponsorProposalRequest, required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_accept(conn, %{"proposal_id" => id} = params),
    do: preview(conn, "sponsor_proposal.accept", id, params)

  operation :accept,
    operation_id: "acceptSponsorProposal",
    summary: "Accept a partnership proposal",
    description:
      """
      Needs `sponsors.proposals.accept` and a fresh key check. `under_review` -> `accepted`, final, for an active organization: SimpleFit will follow up outside the product. Creates nothing: no payment, campaign, placement, advertising entitlement, exposure guarantee, contract or access to athlete or gym data.

      """ <> @confirmed <> @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Decision", "application/json", Schemas.AcceptSponsorProposalRequest, required: true},
    responses: [ok: @ok] ++ @confirmed_errors

  def accept(conn, %{"proposal_id" => id} = params),
    do: execute(conn, "sponsor_proposal.accept", id, params)

  operation :preview_decline,
    operation_id: "previewDeclineSponsorProposal",
    summary: "Preview: decline a partnership proposal",
    description:
      "Needs `sponsors.proposals.decline` and a fresh key check. Changes nothing; returns the impact and a one-time confirmation.\n\n" <>
        @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Decision", "application/json", Schemas.DeclineSponsorProposalRequest, required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_decline(conn, %{"proposal_id" => id} = params),
    do: preview(conn, "sponsor_proposal.decline", id, params)

  operation :decline,
    operation_id: "declineSponsorProposal",
    summary: "Decline a partnership proposal",
    description:
      """
      Needs `sponsors.proposals.decline` and a fresh key check. `under_review` -> `declined`, final. Nothing is created; the reason is internal and never shown to the organization.

      """ <> @confirmed <> @access,
    security: @security,
    parameters: @proposal_id,
    request_body:
      {"Decision", "application/json", Schemas.DeclineSponsorProposalRequest, required: true},
    responses: [ok: @ok] ++ @confirmed_errors

  def decline(conn, %{"proposal_id" => id} = params),
    do: execute(conn, "sponsor_proposal.decline", id, params)

  defp preview(conn, action_id, id, params) do
    with {:ok, preview} <-
           Operators.preview(action_id, user(conn), session(conn), id, body(params), ctx()) do
      conn |> put_view(json: SimpleFitWeb.OperatorJSON) |> render(:preview, preview: preview)
    end
  end

  defp execute(conn, action_id, id, params) do
    with {:ok, review} <-
           Operators.execute(action_id, user(conn), session(conn), id, body(params), ctx()) do
      render(conn, :show, review: review)
    end
  end

  defp body(params), do: Map.drop(params, ["proposal_id", "format"])
  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
