defmodule SimpleFitWeb.CoachFighterController do
  @moduledoc """
  The coach's side of Coach–Fighter relationships (ADR 0021): the roster,
  one fighter as disclosed, and ending a relationship. Every action acts for
  the session's own user; the rules live in `SimpleFit.Coaching`. There is no
  operation that creates a relationship: only a fighter's acceptance does.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFit.Coaching
  alias SimpleFitWeb.{ApiSpec, CoachingParams, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Coaching"]

  @security [%{"bearerAuth" => []}]

  operation :index,
    operation_id: "listMyCoachFighters",
    summary: "My fighters (coach roster)",
    description: """
    The viewer's coaching relationships as their coach, newest first. `status=active` (default) returns each
    fighter with exactly the fields of the disclosure version they accepted (C1 identity, C2 basic boxing
    information) and nothing else; `status=ended` returns stubs: dates, who ended it and the fighter's display
    name as it was at the end, never profile data. An empty list is a real, empty roster.

    * `not_found` - Coach–Fighter sharing is not enabled, or the viewer has no completed coach profile.
    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: CoachingParams.list(),
    responses: [
      ok: {"One page of relationships", "application/json", Schemas.CoachFighterRelationshipList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <-
           Coaching.list_coach_relationships(
             conn.assigns.current_user,
             Map.take(params, ["status", "limit", "cursor"])
           ) do
      conn |> no_store() |> render(:index, page: page)
    end
  end

  operation :show,
    operation_id: "getMyCoachFighter",
    summary: "One of my fighters",
    description: """
    One active relationship of the viewer as coach, with the fighter fields of the accepted disclosure version.
    An ended relationship, someone else's relationship and an unknown id all answer `404 not_found`, as does
    every call while Coach–Fighter sharing is not enabled or without a completed coach profile.
    """,
    security: @security,
    parameters: [CoachingParams.relationship_id()],
    responses: [
      ok: {"The relationship", "application/json", Schemas.CoachFighterRelationshipResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"relationship_id" => id}) do
    with {:ok, entry} <- Coaching.get_coach_relationship(conn.assigns.current_user, id) do
      conn |> no_store() |> render(:show, entry: entry)
    end
  end

  operation :end_relationship,
    operation_id: "endMyCoachFighterRelationship",
    summary: "End a coaching relationship (as coach)",
    description: """
    Ends one of the viewer's relationships as coach. Access to the fighter's data stops at once and the
    relationship can never become active again (a reconnection needs a new acceptance by the fighter). Also
    available while Coach–Fighter sharing is not enabled. Idempotent: ending an ended relationship answers `204`
    and keeps its original end. Someone else's relationship and an unknown id answer `404 not_found`, as does
    a viewer without a completed coach profile.
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
    with :ok <- Coaching.end_relationship(conn.assigns.current_user, :coach, id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
