defmodule SimpleFitWeb.FirstRunController do
  @moduledoc """
  The viewer's one-time first-run experiences (ADR 0018). Every action acts
  on the session's own user; the rules live in `SimpleFit.FirstRun`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Parameter, Schema}
  alias SimpleFit.FirstRun
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["First run"]

  @security [%{"bearerAuth" => []}]

  operation :index,
    operation_id: "listMyFirstRunExperiences",
    summary: "My first-run experiences",
    description: """
    Whether the viewer should be offered each one-time first-run experience. Derived on every call from the
    recorded outcome and the viewer's current state; reading creates nothing. Completing an onboarding never
    records an outcome: a newly onboarded Fighter's tour is `pending`.
    """,
    security: @security,
    responses: [
      ok: {"The viewer's experiences", "application/json", Schemas.FirstRunResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> render(:index, experiences: FirstRun.list_experiences(conn.assigns.current_user))
  end

  operation :record,
    operation_id: "recordMyFirstRunOutcome",
    summary: "Record how I left a first-run experience",
    description: """
    Records that the viewer finished (`completed`) or ended (`dismissed`) the experience, after which it is never
    offered again on any client. The first outcome is final: repeating the request, or sending the other outcome
    (another tab or device), returns the kept outcome with its original `recorded_at`.

    * `not_found` - unknown experience.
    * `conflict` - the experience is `unavailable` to the viewer (for the Fighter experiences, Fighter
      onboarding is not complete); nothing is recorded.
    * `validation_error` - `outcome` is missing (`required`) or not an allowed value (`invalid_choice`).
    """,
    security: @security,
    parameters: [
      %Parameter{
        name: :experience,
        in: :path,
        required: true,
        description: "The experience.",
        schema: %Schema{type: :string, enum: Enum.map(FirstRun.experiences(), &Atom.to_string/1)}
      }
    ],
    request_body:
      {"How the viewer left it", "application/json", Schemas.FirstRunOutcomeRequest,
       required: true},
    responses: [
      ok: {"The experience's kept state", "application/json", Schemas.FirstRunExperienceResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def record(conn, %{"experience" => experience} = params) do
    with {:ok, state} <-
           FirstRun.record_outcome(
             conn.assigns.current_user,
             experience,
             Map.take(params, ["outcome"])
           ) do
      render(conn, :show, experience: state)
    end
  end
end
