defmodule SimpleFitWeb.MyTrainingSessionController do
  @moduledoc """
  The fighter's own training sessions (ADR 0023): every session assigned to
  them, from any coach, whatever the relationship or the sharing gate, and
  completing them (SF-63).
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFit.Training
  alias SimpleFitWeb.{ApiSpec, Schemas, TrainingParams}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.TrainingJSON

  tags ["Training"]

  @security [%{"bearerAuth" => []}]

  operation :index,
    operation_id: "listMyTrainingSessions",
    summary: "My training sessions",
    description: """
    The sessions assigned to the viewer, by start (earliest first, then by id), including those of ended
    relationships (with the coach's name at the end) and cancelled ones. `view=upcoming` / `view=history` select
    the server-computed projections. Filters: `status`, `from` / `to`.

    * `not_found` - the viewer has no completed fighter profile.
    * `validation_error` - a filter, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: TrainingParams.list(:fighter),
    responses: [
      ok: {"One page of sessions", "application/json", Schemas.MyTrainingSessionList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <-
           Training.list_fighter_sessions(
             conn.assigns.current_user,
             Map.take(params, ~w(view status from to limit cursor))
           ) do
      conn |> no_store() |> render(:fighter_index, page: page)
    end
  end

  operation :show,
    operation_id: "getMyTrainingSession",
    summary: "One of my training sessions",
    description: """
    One session assigned to the viewer. Someone else's session, an unknown or malformed id, and a viewer without
    a completed fighter profile all answer `404 not_found`.
    """,
    security: @security,
    parameters: [TrainingParams.session_id()],
    responses: [
      ok: {"The session", "application/json", Schemas.MyTrainingSessionResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"session_id" => id}) do
    with {:ok, session} <- Training.get_fighter_session(conn.assigns.current_user, id) do
      conn |> no_store() |> render(:fighter_show, session: session)
    end
  end

  operation :complete,
    operation_id: "completeMyTrainingSession",
    summary: "Complete one of my training sessions",
    description: """
    Confirms that the viewer did one of their planned sessions. No request body: the server records the
    completion time (`completed_at`, UTC); a client cannot choose it. Allowed from the session's start onwards with
    no deadline, also after the coaching relationship has ended (a session that had already started then stays
    planned) and whatever the Coach–Fighter sharing gate says. Repeating it returns the completed session unchanged.

    * `not_found` - someone else's session, an unknown or malformed id, or no completed fighter profile.
    * `conflict` - the session is cancelled (`details.status: "cancelled"`) or has not started yet
      (`details.starts_at: "not_started"`).
    * `validation_error` - the request sent a field (none is accepted).
    """,
    security: @security,
    parameters: [TrainingParams.session_id()],
    responses: [
      ok: {"The completed session", "application/json", Schemas.MyTrainingSessionResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def complete(conn, %{"session_id" => id} = params) do
    attrs = Map.drop(params, ["session_id", "format"])

    with {:ok, session} <- Training.complete_session(conn.assigns.current_user, id, attrs) do
      conn |> no_store() |> render(:fighter_show, session: session)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
