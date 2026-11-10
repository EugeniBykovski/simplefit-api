defmodule SimpleFitWeb.AdminOverviewController do
  @moduledoc """
  The Control Plane overview (SF-121, AD1): platform counts, review queue sizes and
  health checks for an operator. Read-only, counts only, one fixed projection: there
  is no query language, table name or grouping to pass. The rules live in
  `SimpleFit.Operators.overview/4`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.AdminOverviewJSON

  tags ["Platform operators"]

  operation :show,
    operation_id: "getAdminOverview",
    summary: "The Control Plane overview",
    description: """
    Needs a key check of this session and at least one of `platform.dashboard.read` (platform counts;
    the operator count also `operators.read`), `sponsors.applications.read` (the sponsor review queue)
    or `system.health.read` (health). Each section the operator can't see is `restricted`, without a
    value. Not audited per load (counts only); refusals are.

    * `not_found` - the viewer isn't a usable operator (indistinguishable from an unknown route).
    * `enrollment_required` - the viewer's security keys aren't registered yet.
    * `forbidden` - none of the overview's permissions is granted.
    * `step_up_required` - no key check in this session.
    * `validation_error` - `period` isn't `24h`, `7d` or `30d`.
    """,
    security: [%{"bearerAuth" => []}],
    parameters: [
      period: [
        in: :query,
        description: "The window of the \"in period\" counts, ending now. Default `7d`.",
        schema: %Schema{type: :string, enum: ["24h", "7d", "30d"], default: "7d"},
        required: false
      ]
    ],
    responses: [
      ok: {"The overview", "application/json", Schemas.AdminOverviewResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, params) do
    with {:ok, overview} <-
           Operators.overview(
             conn.assigns.current_user,
             conn.assigns.current_session,
             Map.take(params, ["period"]),
             %{request_id: Logger.metadata()[:request_id]}
           ) do
      render(conn, :show, overview: overview)
    end
  end
end
