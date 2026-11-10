defmodule SimpleFitWeb.SponsorFirstRunController do
  @moduledoc """
  The partner portal first run (SF-119; SRW1 welcome, SRW2 tour): the viewer's
  introduction to one sponsor organization's portal. Every action acts for the
  session's own user on the organization named in the path; the rules live in
  `SimpleFit.Sponsors`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Parameter, Schema}
  alias SimpleFit.Sponsors
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.SponsorFirstRunJSON

  tags ["Sponsors"]

  @security [%{"bearerAuth" => []}]

  @sponsor_id %Parameter{
    name: :sponsor_id,
    in: :path,
    required: true,
    description: "The sponsor organization.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @first_run {"The first run", "application/json", Schemas.SponsorFirstRunResponse}

  @body {"No fields", "application/json", Schemas.SponsorFirstRunTransitionRequest,
         required: false}

  @access """
  * `not_found` - no such organization, it is closed, or the viewer holds no active membership there (revoked,
    suspended or never a member; existence is never revealed).
  """

  @transition_errors """
  * `conflict` - the organization is suspended (`details.organization_status: "suspended"`), or the introduction
    already ended the other way (`details.first_run: "completed"` or `"dismissed"`); nothing changes.
  * `validation_error` - the body has a field (none is accepted).
  """

  @responses [
    ok: @first_run,
    unauthorized: ApiSpec.error_response("unauthorized"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @transition_responses @responses ++
                          [
                            conflict: ApiSpec.error_response("conflict"),
                            unprocessable_entity: ApiSpec.error_response("validation_error")
                          ]

  operation :show,
    operation_id: "getSponsorFirstRun",
    summary: "The viewer's partner portal first run",
    description: """
    The viewer's introduction to this organization's portal: `not_started`, `in_progress`, `completed` or
    `dismissed`, per organization and member, the same on every client and after any sign-in; `unavailable`
    while the organization is suspended. Reading creates nothing, and nothing here grants access.

    #{@access}
    """,
    security: @security,
    parameters: [@sponsor_id],
    responses: @responses

  def show(conn, %{"sponsor_id" => sponsor_id}) do
    with {:ok, first_run} <- Sponsors.get_first_run(conn.assigns.current_user, sponsor_id) do
      conn |> no_store() |> render(:show, first_run: first_run)
    end
  end

  operation :start,
    operation_id: "startSponsorFirstRun",
    summary: "Start the partner portal tour",
    description: """
    Records that the viewer started the tour (`in_progress`), so another client can offer to resume it. Repeating
    it while in progress returns the same state with the first `started_at`.

    #{@access}
    #{@transition_errors}
    """,
    security: @security,
    parameters: [@sponsor_id],
    request_body: @body,
    responses: @transition_responses

  def start(conn, params), do: transition(conn, params, :start)

  operation :complete,
    operation_id: "completeSponsorFirstRun",
    summary: "Finish the partner portal tour",
    description: """
    Records that the viewer finished the tour (`completed`, final). It changes nothing about the organization or
    anyone's access. Repeating it returns the same state with the first `completed_at`.

    #{@access}
    #{@transition_errors}
    """,
    security: @security,
    parameters: [@sponsor_id],
    request_body: @body,
    responses: @transition_responses

  def complete(conn, params), do: transition(conn, params, :complete)

  operation :dismiss,
    operation_id: "dismissSponsorFirstRun",
    summary: "Skip or end the partner portal introduction",
    description: """
    Records that the viewer dismissed the welcome or ended the tour (`dismissed`, final: it is not offered again
    and cannot be resumed). Repeating it returns the same state with the first `dismissed_at`.

    #{@access}
    #{@transition_errors}
    """,
    security: @security,
    parameters: [@sponsor_id],
    request_body: @body,
    responses: @transition_responses

  def dismiss(conn, params), do: transition(conn, params, :dismiss)

  defp transition(conn, %{"sponsor_id" => sponsor_id}, action) do
    with {:ok, first_run} <-
           Sponsors.first_run_transition(
             conn.assigns.current_user,
             sponsor_id,
             action,
             conn.body_params
           ) do
      conn |> no_store() |> render(:show, first_run: first_run)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
