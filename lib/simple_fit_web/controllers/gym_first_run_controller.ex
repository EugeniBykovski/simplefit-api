defmodule SimpleFitWeb.GymFirstRunController do
  @moduledoc """
  The gym first run (SF-90; ADR 0026 D-G21): the owner's introduction to a
  gym and the gym's setup checklist. Every action acts for the session's own
  user on the gym named in the path; the rules live in `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.GymFirstRunJSON

  tags ["Gyms"]

  @security [%{"bearerAuth" => []}]

  @gym_id %Parameter{
    name: :gym_id,
    in: :path,
    required: true,
    description: "The gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @first_run {"The first run", "application/json", Schemas.GymFirstRunResponse}

  @body {"No fields", "application/json", Schemas.GymFirstRunTransitionRequest, required: false}

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never revealed).
  * `forbidden` - the viewer is active staff but not the owner (the first run is the owner's).
  """

  @transition_errors """
  * `conflict` - the gym is a draft (`details.setup_status: "draft"`), or the introduction already ended the
    other way (`details.first_run: "completed"` or `"dismissed"`); nothing changes.
  * `validation_error` - the body has a field (none is accepted).
  """

  @responses [
    ok: @first_run,
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @transition_responses @responses ++
                          [
                            conflict: ApiSpec.error_response("conflict"),
                            unprocessable_entity: ApiSpec.error_response("validation_error")
                          ]

  operation :show,
    operation_id: "getGymFirstRun",
    summary: "A gym's first run and setup checklist",
    description: """
    The owner's introduction to this gym (`not_started`, `in_progress`, `completed`, `dismissed`; `unavailable`
    for a draft) and the gym's opening-week checklist, derived from the gym's own records. The same answer on
    every client and after any sign-in; reading creates nothing.

    #{@access}
    """,
    security: @security,
    parameters: [@gym_id],
    responses: @responses

  def show(conn, %{"gym_id" => gym_id}) do
    with {:ok, first_run} <- Gyms.get_first_run(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:show, first_run: first_run)
    end
  end

  operation :start,
    operation_id: "startGymFirstRun",
    summary: "Start the gym introduction",
    description: """
    Records that the owner started the introduction (`in_progress`), so another client can offer to resume it.
    Repeating it while in progress returns the same state with the first `started_at`.

    #{@access}
    #{@transition_errors}
    """,
    security: @security,
    parameters: [@gym_id],
    request_body: @body,
    responses: @transition_responses

  def start(conn, params), do: transition(conn, params, :start)

  operation :complete,
    operation_id: "completeGymFirstRun",
    summary: "Finish the gym introduction",
    description: """
    Records that the owner finished the introduction (`completed`, final). It marks no checklist item done and
    changes nothing about the gym. Repeating it returns the same state with the first `completed_at`.

    #{@access}
    #{@transition_errors}
    """,
    security: @security,
    parameters: [@gym_id],
    request_body: @body,
    responses: @transition_responses

  def complete(conn, params), do: transition(conn, params, :complete)

  operation :dismiss,
    operation_id: "dismissGymFirstRun",
    summary: "Skip or end the gym introduction",
    description: """
    Records that the owner skipped or ended the introduction (`dismissed`, final: it is not offered again and
    cannot be resumed). It marks no checklist item done. Repeating it returns the same state with the first
    `dismissed_at`.

    #{@access}
    #{@transition_errors}
    """,
    security: @security,
    parameters: [@gym_id],
    request_body: @body,
    responses: @transition_responses

  def dismiss(conn, params), do: transition(conn, params, :dismiss)

  defp transition(conn, %{"gym_id" => gym_id}, action) do
    with {:ok, first_run} <-
           Gyms.first_run_transition(conn.assigns.current_user, gym_id, action, conn.body_params) do
      conn |> no_store() |> render(:show, first_run: first_run)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
