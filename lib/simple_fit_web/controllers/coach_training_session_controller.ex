defmodule SimpleFitWeb.CoachTrainingSessionController do
  @moduledoc """
  The coach's training sessions (ADR 0023): assign a session under one of
  their active relationships, change or cancel it while planned, and read the
  sessions of their active relationships. Every action acts for the
  session's own user; the rules live in `SimpleFit.Training`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFit.Training
  alias SimpleFitWeb.{ApiSpec, Schemas, TrainingParams}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.TrainingJSON

  tags ["Training"]

  @security [%{"bearerAuth" => []}]

  @unavailable """
  * `not_found` - unknown or someone else's session or relationship, a relationship that is not active (or whose
    accepted disclosure no longer applies, for create and update), Coach–Fighter sharing not enabled, or no
    completed coach profile.
  """

  operation :create,
    operation_id: "createMyCoachTrainingSession",
    summary: "Assign a training session",
    description: """
    Creates one planned training session for the fighter of one of the viewer's active relationships (one
    session, one fighter; no group assignment). The fighter is the relationship's; no fighter or coach id is
    accepted. `client_request_id` makes the create idempotent: repeating it returns the same session with `200`
    and creates nothing.

    #{@unavailable}
    * `conflict` - `client_request_id` was already used for another relationship (`details.client_request_id:
      "reused"`).
    * `validation_error` - a field is missing, invalid or unknown; `starts_at` outside the allowed window or with
      an offset that is not `time_zone`'s; `time_zone` not a known IANA zone.
    """,
    security: @security,
    request_body:
      {"The session to assign", "application/json", Schemas.TrainingSessionCreateRequest,
       required: true},
    responses: [
      created: {"Assigned", "application/json", Schemas.CoachTrainingSessionResponse},
      ok:
        {"Already assigned with this client_request_id", "application/json",
         Schemas.CoachTrainingSessionResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create(conn, params) do
    with {:ok, session, outcome} <-
           Training.create_session(conn.assigns.current_user, Map.drop(params, ["format"])) do
      conn
      |> no_store()
      |> put_status(if outcome == :created, do: :created, else: :ok)
      |> render(:coach_show, session: session)
    end
  end

  operation :index,
    operation_id: "listMyCoachTrainingSessions",
    summary: "My assigned training sessions (coach)",
    description: """
    The sessions of the viewer's active relationships, by start (earliest first, then by id). Sessions of ended
    relationships are not listed. Filters: `status`, `from` / `to` (start instants), `relationship_id`.

    * `not_found` - Coach–Fighter sharing is not enabled, or no completed coach profile.
    * `validation_error` - a filter, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: TrainingParams.list(:coach),
    responses: [
      ok: {"One page of sessions", "application/json", Schemas.CoachTrainingSessionList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <-
           Training.list_coach_sessions(
             conn.assigns.current_user,
             Map.take(params, ~w(status from to relationship_id limit cursor))
           ) do
      conn |> no_store() |> render(:coach_index, page: page)
    end
  end

  operation :show,
    operation_id: "getMyCoachTrainingSession",
    summary: "One assigned training session (coach)",
    description: """
    One session of the viewer's active relationships.

    #{@unavailable}
    """,
    security: @security,
    parameters: [TrainingParams.session_id()],
    responses: [
      ok: {"The session", "application/json", Schemas.CoachTrainingSessionResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"session_id" => id}) do
    with {:ok, session} <- Training.get_coach_session(conn.assigns.current_user, id) do
      conn |> no_store() |> render(:coach_show, session: session)
    end
  end

  operation :update,
    operation_id: "updateMyCoachTrainingSession",
    summary: "Change a planned training session",
    description: """
    Changes the plan of one of the viewer's planned sessions; only the fields sent change. The status, the
    relationship and the fighter cannot change here.

    #{@unavailable}
    * `conflict` - the session is completed or cancelled (`details.status`).
    * `validation_error` - a field is invalid or unknown (as for create).
    """,
    security: @security,
    parameters: [TrainingParams.session_id()],
    request_body:
      {"The fields to change", "application/json", Schemas.TrainingSessionUpdateRequest,
       required: true},
    responses: [
      ok: {"The changed session", "application/json", Schemas.CoachTrainingSessionResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update(conn, %{"session_id" => id} = params) do
    attrs = Map.drop(params, ["session_id", "format"])

    with {:ok, session} <- Training.update_session(conn.assigns.current_user, id, attrs) do
      conn |> no_store() |> render(:coach_show, session: session)
    end
  end

  operation :cancel,
    operation_id: "cancelMyCoachTrainingSession",
    summary: "Cancel a planned training session",
    description: """
    Cancels one of the viewer's planned sessions (`cancelled_by: coach`). Repeating it returns the cancelled
    session unchanged.

    #{@unavailable}
    * `conflict` - the session is completed (`details.status: "completed"`).
    """,
    security: @security,
    parameters: [TrainingParams.session_id()],
    responses: [
      ok: {"The cancelled session", "application/json", Schemas.CoachTrainingSessionResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel(conn, %{"session_id" => id}) do
    with {:ok, session} <- Training.cancel_session(conn.assigns.current_user, id) do
      conn |> no_store() |> render(:coach_show, session: session)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
