defmodule SimpleFitWeb.AdminSponsorApplicationController do
  @moduledoc """
  Sponsor application review for platform operators (SF-114, ADR 0032; SF-116, ADR
  0033): the audited queue and detail, audited document downloads, and declared admin
  actions through the SF-111 framework (claim, request changes, approve, reject,
  suspend or reinstate the organization an approval created). Everything answers
  `not_found` to an account without a usable operator.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
  alias SimpleFit.Sponsors.Review
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.AdminSponsorApplicationJSON

  tags ["Platform operators"]

  @security [%{"bearerAuth" => []}]
  @application_id [
    application_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
  ]

  @access """
  * `not_found` - not a usable operator, or no such submitted application (drafts are never visible).
  * `enrollment_required`, `forbidden` (permission), `step_up_required` (key check).
  * `conflict` - `details.target: "self"` (the operator's own application), or the application's status.
  * `revision_conflict` - the application changed since `expected_revision`.
  """

  @ok {"The application", "application/json", Schemas.SponsorApplicationReviewResponse}

  @confirmed """
  Needs a one-time `confirmation_token` from a preview of exactly this request (same operator, session,
  application, revision and reason), with `reason_code`, `expected_revision` and `operation_id` (a repeat of
  the same request returns the current state and changes nothing).
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

  operation :index,
    operation_id: "listSponsorApplicationsForReview",
    summary: "The sponsor application review queue",
    description:
      """
      Needs `sponsors.applications.read` and a key check. Submitted applications (never drafts), oldest
      submission first, with what the latest submission says about the company and nothing about the contact.
      `limit` 1..100 (default 50); `cursor` from the previous page, valid only for the same filters and reader.
      Each query is audited.

      """ <> @access,
    security: @security,
    parameters: [
      status: [
        in: :query,
        schema: %Schema{
          type: :string,
          enum: Enum.map(Review.queue_statuses(), &Atom.to_string/1)
        }
      ],
      submitted_after: [in: :query, schema: %Schema{type: :string, format: :"date-time"}],
      submitted_before: [in: :query, schema: %Schema{type: :string, format: :"date-time"}],
      limit: [in: :query, schema: %Schema{type: :integer, minimum: 1, maximum: 100}],
      cursor: [in: :query, schema: %Schema{type: :string, maxLength: 1024}]
    ],
    responses:
      [ok: {"A page", "application/json", Schemas.SponsorApplicationQueueResponse}] ++ @base

  def index(conn, params) do
    with {:ok, page} <-
           Operators.list_sponsor_applications(user(conn), session(conn), params, ctx()) do
      render(conn, :index, page: page)
    end
  end

  operation :download,
    operation_id: "downloadSponsorApplicationDocument",
    summary: "Download a submitted document of a sponsor application",
    description:
      """
      Needs `sponsors.applications.read_files` and a fresh key check. A presigned `GET` valid for 5 minutes that
      always downloads as an attachment (`application/octet-stream`); only documents that were part of a
      submission; never the operator's own application. Audited before the URL is returned. The URL is a
      credential: never log, store or share it. Documents are not scanned for malware.

      """ <> @access,
    security: @security,
    parameters:
      @application_id ++
        [evidence_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]],
    responses:
      [
        ok:
          {"The download", "application/json", Schemas.SponsorApplicationDocumentDownloadResponse},
        service_unavailable: ApiSpec.error_response("service_unavailable")
      ] ++ @base

  def download(conn, %{"application_id" => id, "evidence_id" => evidence_id}) do
    with {:ok, download} <-
           Operators.download_sponsor_application_document(
             user(conn),
             session(conn),
             id,
             evidence_id,
             ctx()
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> render(:download, download: download)
    end
  end

  operation :show,
    operation_id: "getSponsorApplicationForReview",
    summary: "A sponsor application for review",
    description:
      "Needs `sponsors.applications.read` and a key check. Exactly what was last submitted. Each view is audited.\n\n" <>
        @access,
    security: @security,
    parameters: @application_id,
    responses: [ok: @ok] ++ @base

  def show(conn, %{"application_id" => id}) do
    with {:ok, review} <- Operators.get_sponsor_application(user(conn), session(conn), id, ctx()) do
      render(conn, :show, review: review)
    end
  end

  operation :preview_claim,
    operation_id: "previewClaimSponsorApplication",
    summary: "Preview claiming a sponsor application",
    description:
      "Needs `sponsors.applications.claim` and a fresh key check. Changes nothing.\n\n" <> @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Claim", "application/json", Schemas.ClaimSponsorApplicationRequest, required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_claim(conn, %{"application_id" => id} = params),
    do: preview(conn, "sponsor_application.claim", id, params)

  operation :claim,
    operation_id: "claimSponsorApplication",
    summary: "Claim a sponsor application for review",
    description:
      "Needs `sponsors.applications.claim` and a fresh key check: `submitted` -> `under_review`. " <>
        "Takes `reason_code`, `expected_revision` and `operation_id` (a repeat changes nothing).\n\n" <>
        @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Claim", "application/json", Schemas.ClaimSponsorApplicationRequest, required: true},
    responses: [ok: @ok] ++ @base

  def claim(conn, %{"application_id" => id} = params),
    do: execute(conn, "sponsor_application.claim", id, params)

  operation :preview_request_changes,
    operation_id: "previewRequestSponsorApplicationChanges",
    summary: "Preview requesting changes",
    description:
      "Needs `sponsors.applications.request_changes` and a fresh key check. Changes nothing.\n\n" <>
        @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Change request", "application/json", Schemas.RequestSponsorApplicationChangesRequest,
       required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_request_changes(conn, %{"application_id" => id} = params),
    do: preview(conn, "sponsor_application.request_changes", id, params)

  operation :request_changes,
    operation_id: "requestSponsorApplicationChanges",
    summary: "Request changes to a sponsor application",
    description:
      """
      Needs `sponsors.applications.request_changes` and a fresh key check: `under_review` -> `changes_requested`,
      with the answers the applicant may change and a plain-text message (also emailed where enabled). The
      applicant's next submission resolves it. Takes `reason_code`, `expected_revision` and `operation_id`.

      """ <> @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Change request", "application/json", Schemas.RequestSponsorApplicationChangesRequest,
       required: true},
    responses: [ok: @ok] ++ @base

  def request_changes(conn, %{"application_id" => id} = params),
    do: execute(conn, "sponsor_application.request_changes", id, params)

  operation :preview_approve,
    operation_id: "previewApproveSponsorApplication",
    summary: "Preview: approve a sponsor application",
    description:
      "Needs `sponsors.applications.approve` and a fresh key check. Changes nothing; returns the impact and a one-time confirmation.\n\n" <>
        @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Decision", "application/json", Schemas.ApproveSponsorApplicationRequest, required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_approve(conn, %{"application_id" => id} = params),
    do: preview(conn, "sponsor_application.approve", id, params)

  operation :approve,
    operation_id: "approveSponsorApplication",
    summary: "Approve a sponsor application",
    description:
      """
      Needs `sponsors.applications.approve` and a fresh key check. `under_review` -> `approved`. In one transaction: the organization (from exactly what was last submitted) and the applicant as its owner, the audit event and the applicant's email intent. A repeat makes no second organization. Grants no contract, plan, placement, entitlement, payment or public listing.

      """ <> @confirmed <> @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Decision", "application/json", Schemas.ApproveSponsorApplicationRequest, required: true},
    responses: [ok: @ok] ++ @base

  def approve(conn, %{"application_id" => id} = params),
    do: execute(conn, "sponsor_application.approve", id, params)

  operation :preview_reject,
    operation_id: "previewRejectSponsorApplication",
    summary: "Preview: reject a sponsor application",
    description:
      "Needs `sponsors.applications.reject` and a fresh key check. Changes nothing; returns the impact and a one-time confirmation.\n\n" <>
        @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Decision", "application/json", Schemas.RejectSponsorApplicationRequest, required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_reject(conn, %{"application_id" => id} = params),
    do: preview(conn, "sponsor_application.reject", id, params)

  operation :reject,
    operation_id: "rejectSponsorApplication",
    summary: "Reject a sponsor application",
    description:
      """
      Needs `sponsors.applications.reject` and a fresh key check. `under_review` -> `rejected`, final. Nothing is created; the reason is internal and never shown to the applicant.

      """ <> @confirmed <> @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Decision", "application/json", Schemas.RejectSponsorApplicationRequest, required: true},
    responses: [ok: @ok] ++ @base

  def reject(conn, %{"application_id" => id} = params),
    do: execute(conn, "sponsor_application.reject", id, params)

  operation :preview_suspend_organization,
    operation_id: "previewSuspendSponsorApplicationOrganization",
    summary: "Preview: suspend the organization of an approved application",
    description:
      "Needs `sponsors.restrict` and a fresh key check. Changes nothing; returns the impact and a one-time confirmation.\n\n" <>
        @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Decision", "application/json", Schemas.SuspendSponsorOrganizationRequest, required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_suspend_organization(conn, %{"application_id" => id} = params),
    do: preview(conn, "sponsor_application.suspend_organization", id, params)

  operation :suspend_organization,
    operation_id: "suspendSponsorApplicationOrganization",
    summary: "Suspend the organization of an approved application",
    description:
      """
      Needs `sponsors.restrict` and a fresh key check. The organization this approval created: `active` -> `suspended` (read-only for its members, no workspace entry). The application stays approved; nothing is deleted; no other organization or membership changes. `conflict` with `details.organization` when it isn't active.

      """ <> @confirmed <> @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Decision", "application/json", Schemas.SuspendSponsorOrganizationRequest, required: true},
    responses: [ok: @ok] ++ @base

  def suspend_organization(conn, %{"application_id" => id} = params),
    do: execute(conn, "sponsor_application.suspend_organization", id, params)

  operation :preview_reinstate_organization,
    operation_id: "previewReinstateSponsorApplicationOrganization",
    summary: "Preview: reinstate the organization of an approved application",
    description:
      "Needs `sponsors.restrict` and a fresh key check. Changes nothing; returns the impact and a one-time confirmation.\n\n" <>
        @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Decision", "application/json", Schemas.ReinstateSponsorOrganizationRequest,
       required: true},
    responses: [ok: @preview_ok] ++ @base

  def preview_reinstate_organization(conn, %{"application_id" => id} = params),
    do: preview(conn, "sponsor_application.reinstate_organization", id, params)

  operation :reinstate_organization,
    operation_id: "reinstateSponsorApplicationOrganization",
    summary: "Reinstate the organization of an approved application",
    description:
      """
      Needs `sponsors.restrict` and a fresh key check. The organization this approval created: `suspended` -> `active`.

      """ <> @confirmed <> @access,
    security: @security,
    parameters: @application_id,
    request_body:
      {"Decision", "application/json", Schemas.ReinstateSponsorOrganizationRequest,
       required: true},
    responses: [ok: @ok] ++ @base

  def reinstate_organization(conn, %{"application_id" => id} = params),
    do: execute(conn, "sponsor_application.reinstate_organization", id, params)

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

  defp body(params), do: Map.drop(params, ["application_id", "format"])
  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
