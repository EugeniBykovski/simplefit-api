defmodule SimpleFitWeb.MyCoachController do
  @moduledoc """
  The fighter's side of Coach–Fighter relationships (ADR 0021): their own
  coaches and ending a relationship. Every action acts for the session's own
  user; the rules live in `SimpleFit.Coaching`. Available whatever the
  Coach–Fighter sharing gate says, so a fighter can always see and remove
  who has access.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFit.Coaching
  alias SimpleFitWeb.{ApiSpec, CoachingParams, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Coaching"]

  @security [%{"bearerAuth" => []}]

  operation :index,
    operation_id: "listMyCoaches",
    summary: "My coaches",
    description: """
    The viewer's coaching relationships as fighter, newest first. `status=active` (default) returns each coach's
    public identity and the fields of the viewer's profile disclosed to them; `status=ended` returns the coach's
    name as it was at the end, the dates and who ended it.

    * `not_found` - the viewer has no completed fighter profile.
    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: CoachingParams.list(),
    responses: [
      ok: {"One page of relationships", "application/json", Schemas.MyCoachRelationshipList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <-
           Coaching.list_fighter_relationships(
             conn.assigns.current_user,
             Map.take(params, ["status", "limit", "cursor"])
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> render(:index, page: page)
    end
  end

  operation :end_relationship,
    operation_id: "endMyCoachRelationship",
    summary: "End a coaching relationship (as fighter)",
    description: """
    Removes a coach's access: ends one of the viewer's relationships as fighter. The coach stops seeing the
    viewer's data at once and the relationship can never become active again. Idempotent: ending an ended
    relationship answers `204` and keeps its original end. Someone else's relationship and an unknown id answer
    `404 not_found`, as does a viewer without a completed fighter profile.
    """,
    security: @security,
    parameters: [CoachingParams.relationship_id()],
    responses: [
      no_content: "Ended (or already ended)",
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def end_relationship(conn, %{"relationship_id" => id}) do
    with :ok <- Coaching.end_relationship(conn.assigns.current_user, :fighter, id) do
      send_resp(conn, :no_content, "")
    end
  end
end
