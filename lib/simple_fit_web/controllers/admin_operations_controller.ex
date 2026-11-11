defmodule SimpleFitWeb.AdminOperationsController do
  @moduledoc """
  Operator operations (SF-126): the measured system health page and the background job
  list and detail. Read only: no retry, replay, queue control, log search, SQL or
  deploy action exists. The rules live in `SimpleFit.Operators` and
  `SimpleFit.Observability.Operations`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Observability.Operations
  alias SimpleFit.Operators
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.AdminOperationsJSON

  tags ["Platform operators"]

  @security [%{"bearerAuth" => []}]

  @access """
  * `not_found` - not a usable operator (indistinguishable from an unknown route), or no such job.
  * `enrollment_required`, `forbidden` (permission), `step_up_required` (key check).
  """

  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  operation :health,
    operation_id: "getAdminOperationsHealth",
    summary: "The system health page",
    description:
      "Needs `system.health.read` and a key check. Measured checks with their status and observation time, " <>
        "job counts per queue and state, applied migrations and the configured release. No uptime or SLA " <>
        "figure exists.\n\n" <> @access,
    security: @security,
    responses:
      [ok: {"Health", "application/json", Schemas.AdminOperationsHealthResponse}] ++ @base

  def health(conn, _params) do
    with {:ok, health} <- Operators.operations_health(user(conn), session(conn), ctx()) do
      conn |> put_resp_header("cache-control", "no-store") |> render(:health, health: health)
    end
  end

  operation :jobs,
    operation_id: "listAdminJobs",
    summary: "One page of background jobs",
    description:
      "Needs `system.jobs.read` and a key check. Newest first; metadata only (never arguments, `meta` or error " <>
        "messages). Every query is recorded (`jobs.listed`).\n\n" <>
        @access <> "* `validation_error` - an unknown filter value or an invalid cursor.",
    security: @security,
    parameters: [
      state: [in: :query, schema: %Schema{type: :string, enum: Operations.states()}],
      queue: [in: :query, schema: %Schema{type: :string}],
      worker: [in: :query, schema: %Schema{type: :string, enum: Operations.workers()}],
      limit: [in: :query, schema: %Schema{type: :integer, minimum: 1, maximum: 50, default: 25}],
      cursor: [in: :query, schema: %Schema{type: :string, maxLength: 1024}]
    ],
    responses:
      [
        ok: {"A page", "application/json", Schemas.AdminJobListResponse},
        unprocessable_entity: ApiSpec.error_response("validation_error")
      ] ++ @base

  def jobs(conn, params) do
    with {:ok, page} <-
           Operators.list_jobs(
             user(conn),
             session(conn),
             Map.take(params, ~w(state queue worker limit cursor)),
             ctx()
           ) do
      conn |> put_resp_header("cache-control", "no-store") |> render(:jobs, page: page)
    end
  end

  operation :job,
    operation_id: "getAdminJob",
    summary: "One background job",
    description:
      "Needs `system.jobs.read` and a key check. Metadata only; recorded (`job.viewed`). No retry is offered.\n\n" <>
        @access,
    security: @security,
    parameters: [job_id: [in: :path, schema: %Schema{type: :integer, minimum: 1}, required: true]],
    responses: [ok: {"The job", "application/json", Schemas.AdminJobResponse}] ++ @base

  def job(conn, %{"job_id" => id}) do
    with {:ok, job} <- Operators.get_job(user(conn), session(conn), id, ctx()) do
      conn |> put_resp_header("cache-control", "no-store") |> render(:show, job: job)
    end
  end

  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
