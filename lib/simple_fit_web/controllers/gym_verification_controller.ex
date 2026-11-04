defmodule SimpleFitWeb.GymVerificationController do
  @moduledoc """
  A gym's business verification (SF-103, OG7) and go-live readiness (OG14;
  ADR 0026 amendment SF-103). The owner drafts, uploads documents and
  submits; **no endpoint decides an application** (SimpleFit operators do,
  outside the API) and none publishes a gym. The rules live in
  `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.GymVerificationJSON

  tags ["Gym verification"]

  @security [%{"bearerAuth" => []}]

  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{
                   "retry-after" => %Header{
                     description: "Seconds until another request is accepted.",
                     schema: %Schema{type: :integer}
                   }
                 }}

  @gym_id %Parameter{
    name: :gym_id,
    in: :path,
    required: true,
    description: "The gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @evidence_id %Parameter{
    name: :evidence_id,
    in: :path,
    required: true,
    description: "A document of the gym's current application.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never revealed).
  * `forbidden` - only the gym's owner reads and writes its verification (`manage_business_verification`);
    managers, coaches and front desk do not.
  """

  @write_errors """
  * `conflict` - `details.revision: "stale"` (with `current_revision`; reload and retry); `details.verification`
    names a status that does not allow the change (`submitted`, `approved`, ... or `not_started`); a draft gym
    (`details.setup_status`).
  * `rate_limited` - 60 changes per 10 minutes per user.
  """

  @verification {"The verification", "application/json", Schemas.GymBusinessVerificationResponse}

  @read_responses [
    ok: @verification,
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @write_responses @read_responses ++
                     [
                       conflict: ApiSpec.error_response("conflict"),
                       unprocessable_entity: ApiSpec.error_response("validation_error"),
                       too_many_requests: @rate_limited
                     ]

  @revision_body {"The revision", "application/json",
                  Schemas.GymBusinessVerificationRevisionRequest, required: true}

  operation :show,
    operation_id: "getGymBusinessVerification",
    summary: "A gym's business verification",
    description: """
    The current application (or the latest rejected or revoked one), its documents, the latest operator decision,
    what submission still needs and the requirement policy. Reading creates nothing.

    #{@access}
    """,
    security: @security,
    parameters: [@gym_id],
    responses: @read_responses

  def show(conn, %{"gym_id" => gym_id}) do
    with {:ok, view} <- Gyms.get_business_verification(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:show, verification: view)
    end
  end

  operation :save,
    operation_id: "saveGymBusinessVerification",
    summary: "Save the verification draft",
    description: """
    Starts an application (`201`, no `revision`, when the gym has none current) or changes the details of the
    current draft or of an application with changes requested (`200`, `revision` = its revision). Every change
    bumps the revision. Nothing is required while drafting; nothing here submits or approves.

    #{@access}
    #{@write_errors}
    * `validation_error` - an invalid value (country, website, length, control characters) or an unknown field.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"The details", "application/json", Schemas.GymBusinessVerificationRequest, required: true},
    responses: [{:created, @verification} | @write_responses]

  def save(conn, %{"gym_id" => gym_id}) do
    with {:ok, {view, outcome}} <-
           Gyms.save_business_verification(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:show, verification: view)
    end
  end

  operation :submit,
    operation_id: "submitGymBusinessVerification",
    summary: "Submit the application for review",
    description: """
    Submits the current application at `revision` to SimpleFit's operators. It needs the policy's required fields
    and enough confirmed documents, and no upload still pending. Submitting the revision that is already
    submitted returns it unchanged. A submission is never an approval.

    #{@access}
    #{@write_errors}
    * `conflict` - also `details.evidence: "upload_pending"` (confirm or remove pending uploads first).
    * `validation_error` - a required field is blank or `evidence` has too few documents (`fields`).
    """,
    security: @security,
    parameters: [@gym_id],
    request_body: @revision_body,
    responses: @write_responses

  def submit(conn, %{"gym_id" => gym_id}) do
    with {:ok, view} <-
           Gyms.submit_business_verification(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:show, verification: view)
    end
  end

  operation :create_evidence,
    operation_id: "createGymVerificationEvidence",
    summary: "Announce a document and get its upload",
    description: """
    Announces a document of the current editable application at `revision` (kind, base file name, content type
    and exact size within the policy) and returns a presigned direct upload to private storage, valid for 15
    minutes, that accepts only that type and size. The document stays `pending_upload` until confirmed.

    #{@access}
    #{@write_errors}
    * `conflict` - also `details.evidence: "limit_reached"`.
    * `validation_error` - a kind, content type or size outside the policy, an empty file name, an unknown field.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"The document", "application/json", Schemas.GymVerificationEvidenceRequest, required: true},
    responses:
      [
        created:
          {"The document and its upload", "application/json",
           Schemas.GymVerificationEvidenceResponse}
      ] ++ Keyword.delete(@write_responses, :ok)

  def create_evidence(conn, %{"gym_id" => gym_id}) do
    with {:ok, {view, evidence, upload}} <-
           Gyms.add_business_verification_evidence(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(:created)
      |> render(:evidence, verification: view, evidence: evidence, upload: upload)
    end
  end

  operation :confirm_evidence,
    operation_id: "confirmGymVerificationEvidence",
    summary: "Confirm an uploaded document",
    description: """
    The server reads the stored object's size and type itself and attaches the document only when they match
    what was announced. Confirming an attached document again returns the verification.

    #{@access}
    * `not_found` - also an unknown document, or one of another application or gym.
    #{@write_errors}
    * `conflict` - also `details.upload: "not_found"` (nothing was uploaded) or `"mismatch"` (another size or
      type), `details.evidence: "removed"`.
    * `service_unavailable` - storage could not be reached; retry.
    """,
    security: @security,
    parameters: [@gym_id, @evidence_id],
    responses:
      @write_responses ++ [service_unavailable: ApiSpec.error_response("service_unavailable")]

  def confirm_evidence(conn, %{"gym_id" => gym_id, "evidence_id" => evidence_id}) do
    with {:ok, view} <-
           Gyms.confirm_business_verification_evidence(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             evidence_id
           ) do
      conn |> no_store() |> render(:show, verification: view)
    end
  end

  operation :remove_evidence,
    operation_id: "removeGymVerificationEvidence",
    summary: "Remove a document",
    description: """
    Removes a document of the current editable application at `revision` that was never part of a submission;
    its stored file is deleted later. Removing it again returns the verification.

    #{@access}
    * `not_found` - also an unknown document, or one of another application or gym.
    #{@write_errors}
    * `conflict` - also `details.evidence: "submitted"` (submitted documents are frozen).
    """,
    security: @security,
    parameters: [@gym_id, @evidence_id],
    request_body: @revision_body,
    responses: @write_responses

  def remove_evidence(conn, %{"gym_id" => gym_id, "evidence_id" => evidence_id}) do
    with {:ok, view} <-
           Gyms.remove_business_verification_evidence(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             evidence_id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:show, verification: view)
    end
  end

  operation :go_live,
    operation_id: "getGymGoLive",
    summary: "A gym's go-live readiness",
    description: """
    The readiness checklist derived on this read from the gym's records (setup, primary location, business
    verification, upcoming classes, staff, members, member products, member payments, and the future public
    profile and community settings), each with its requiredness under the versioned policy. Nothing is stored
    and nothing is published: `publication.status` is `unavailable` (no approved public gym surface).

    * `not_found` - no such gym, or the viewer holds no active staff membership there.
    * `forbidden` - only the owner and managers read it (`view_go_live`).
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: {"The readiness", "application/json", Schemas.GymGoLiveResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def go_live(conn, %{"gym_id" => gym_id}) do
    with {:ok, readiness} <- Gyms.get_go_live(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:go_live, go_live: readiness)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
