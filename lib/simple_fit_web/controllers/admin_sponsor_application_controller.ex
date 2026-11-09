defmodule SimpleFitWeb.AdminSponsorApplicationController do
  @moduledoc """
  Sponsor application review for platform operators (SF-114, ADR 0032): an audited
  read and two declared admin actions (claim, request changes) through the SF-111
  framework. Everything answers `not_found` to an account without a usable
  operator. There is no approval or rejection here.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
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
