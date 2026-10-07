defmodule SimpleFitWeb.FighterProfileController do
  @moduledoc """
  The authenticated user's fighter profile and resumable Fighter onboarding
  (ADR 0015). Every action acts on the session's own user; the rules live in
  `SimpleFit.Fighters`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFit.Fighters
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Fighter profile"]

  @security [%{"bearerAuth" => []}]
  @profile_response {"The fighter profile and onboarding state", "application/json",
                     Schemas.FighterProfileResponse}

  operation :show,
    operation_id: "getMyFighterProfile",
    summary: "My fighter profile and onboarding state",
    description: """
    Returns the current Fighter onboarding state and every saved field. Before onboarding has started the
    response is still `200`, with `onboarding.status: not_started`, empty fields and every requirement listed
    as missing; no profile is created by reading.
    """,
    security: @security,
    responses: [
      ok: @profile_response,
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, _params) do
    render(conn, :show, profile: Fighters.get_profile(conn.assigns.current_user))
  end

  operation :update,
    operation_id: "updateMyFighterProfile",
    summary: "Save Fighter onboarding progress",
    description: """
    Saves any subset of the fighter profile; the first save creates the profile (`in_progress`). Values are
    validated but nothing is required until completion. An invalid request changes nothing.
    """,
    security: @security,
    request_body:
      {"Fields to save", "application/json", Schemas.FighterProfileUpdateRequest, required: true},
    responses: [
      ok: @profile_response,
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update(conn, params) do
    attrs = Map.take(params, Enum.map(Fighters.FighterProfile.editable_fields(), &to_string/1))

    with {:ok, profile} <- Fighters.update_profile(conn.assigns.current_user, attrs) do
      render(conn, :show, profile: profile)
    end
  end

  operation :complete_onboarding,
    operation_id: "completeFighterOnboarding",
    summary: "Complete Fighter onboarding",
    description: """
    Records that Fighter onboarding is complete, after checking every requirement on the server. While any
    required field is missing the response is `422 validation_error` with a `required` field code per missing
    field, and nothing changes. Completing again returns the profile with its original `completed_at`.
    """,
    security: @security,
    responses: [
      ok: @profile_response,
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def complete_onboarding(conn, _params) do
    with {:ok, profile} <- Fighters.complete_onboarding(conn.assigns.current_user) do
      render(conn, :show, profile: profile)
    end
  end
end
