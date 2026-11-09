defmodule SimpleFitWeb.SponsorApplicationController do
  @moduledoc """
  The viewer's own sponsor application (SF-113, ADR 0031). Every route acts on the
  authenticated user's application only: no application, owner or user id is ever
  taken from the request. Needs completed account registration, and no sponsor
  membership, organization or operator authority. Nothing here approves, rejects
  or provisions anything.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.Applications
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Sponsor applications"]

  @security [%{"bearerAuth" => []}]
  @ok {"The application", "application/json", Schemas.SponsorApplicationResponse}
  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  operation :show,
    operation_id: "getMySponsorApplication",
    summary: "My sponsor application",
    description: """
    The viewer's current application (draft, submitted, under review, changes requested), otherwise their latest,
    with the answers saved so far, what a submission still needs and what the viewer can do now.

    * `not_found` - the viewer has no application. Choosing the sponsor journey creates none.
    """,
    security: @security,
    responses: [ok: @ok, not_found: ApiSpec.error_response("not_found")] ++ @base

  def show(conn, _params) do
    with {:ok, view} <- Applications.get(conn.assigns.current_user) do
      render(conn, :show, view: view)
    end
  end

  operation :save,
    operation_id: "saveMySponsorApplication",
    summary: "Save answers to my sponsor application",
    description: """
    Saves any subset of the answers. The first save with at least one non-blank answer starts the draft
    (`client_request_id`; repeating it answers the same); every later save names `expected_revision`. Only the
    sent answers change, each validated now; nothing a later step needs is required yet. An invalid save changes
    nothing. Editable only in `draft` and `changes_requested`.

    * `revision_conflict` - the application changed since `expected_revision` (another device); read it again.
    * `conflict` - `details.application`: `not_editable` (submitted or decided), `reapplication_unavailable`
      (a rejected or withdrawn application exists and reapplication isn't decided, D-SA03), `exists`;
      `details.client_request_id: "reused"`; `details.account_registration: "incomplete"`.
    * `validation_error` - per field (`fields`, `field_codes`); `answers` when nothing was given to start with.
    * `rate_limited`.
    """,
    security: @security,
    request_body:
      {"Answers", "application/json", Schemas.SponsorApplicationSaveRequest, required: true},
    responses:
      [
        ok: @ok,
        conflict: ApiSpec.error_response("conflict"),
        unprocessable_entity: ApiSpec.error_response("validation_error"),
        too_many_requests: ApiSpec.error_response("rate_limited")
      ] ++ @base

  def save(conn, params) do
    with {:ok, view} <-
           Applications.save(conn.assigns.current_user, Map.drop(params, ["format"]), ctx()) do
      render(conn, :show, view: view)
    end
  end

  operation :submit,
    operation_id: "submitMySponsorApplication",
    summary: "Submit my sponsor application",
    description: """
    Submits the draft (or the application whose changes were requested) for review: checks the revision, the
    accepted published declaration and every required answer, then stores an immutable copy of what was sent and
    moves the application to `submitted`, in one transaction. Repeating the same request with the same
    `client_request_id` answers the same and sends nothing new. Submitting grants nothing.

    * `validation_error` - `field_codes` name each missing answer (`required`), or a malformed request.
    * `revision_conflict` - the application changed since `expected_revision`.
    * `conflict` - `details.declaration`: `unavailable` (none published; submission is closed) or `stale` (a newer
      version); `details.application: "not_submittable"`; `details.client_request_id: "reused"`.
    * `not_found` - the viewer has no current application.
    * `rate_limited`.
    """,
    security: @security,
    request_body:
      {"Submission", "application/json", Schemas.SponsorApplicationSubmitRequest, required: true},
    responses:
      [
        ok: @ok,
        not_found: ApiSpec.error_response("not_found"),
        conflict: ApiSpec.error_response("conflict"),
        unprocessable_entity: ApiSpec.error_response("validation_error"),
        too_many_requests: ApiSpec.error_response("rate_limited")
      ] ++ @base

  def submit(conn, params) do
    with {:ok, view} <-
           Applications.submit(conn.assigns.current_user, Map.drop(params, ["format"]), ctx()) do
      render(conn, :show, view: view)
    end
  end

  operation :submission,
    operation_id: "getMySponsorApplicationSubmission",
    summary: "One of my submissions",
    description:
      "Exactly what one submission of the viewer's application sent. `not_found` for any other id.",
    security: @security,
    parameters: [
      submission_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses:
      [
        ok: {"The submission", "application/json", Schemas.SponsorApplicationSubmissionResponse},
        not_found: ApiSpec.error_response("not_found")
      ] ++ @base

  def submission(conn, %{"submission_id" => id}) do
    with {:ok, submission} <- Applications.get_submission(conn.assigns.current_user, id) do
      render(conn, :submission, submission: submission)
    end
  end

  operation :policy,
    operation_id: "getSponsorApplicationPolicy",
    summary: "What a sponsor application accepts",
    description:
      "The validation policy: steps and their fields, what a submission needs, the allowed codes, budget bands, uploads availability and the declaration to accept.",
    security: @security,
    responses:
      [ok: {"Policy", "application/json", Schemas.SponsorApplicationPolicyResponse}] ++ @base

  def policy(conn, _params), do: render(conn, :policy, policy: Applications.policy())

  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
