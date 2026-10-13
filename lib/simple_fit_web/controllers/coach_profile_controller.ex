defmodule SimpleFitWeb.CoachProfileController do
  @moduledoc """
  The authenticated user's coach profile and resumable Coach onboarding
  (ADR 0020). Every action acts on the session's own user; the rules live in
  `SimpleFit.Coaches`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFit.Coaches
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Coach profile"]

  @security [%{"bearerAuth" => []}]
  @profile_response {"The coach profile and onboarding state", "application/json",
                     Schemas.CoachProfileResponse}

  operation :show,
    operation_id: "getMyCoachProfile",
    summary: "My coach profile and onboarding state",
    description: """
    Returns the current Coach onboarding state and every saved field. Before onboarding has started the
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
    render_profile(conn, Coaches.get_profile(conn.assigns.current_user))
  end

  operation :update,
    operation_id: "updateMyCoachProfile",
    summary: "Save Coach onboarding progress",
    description: """
    Saves any subset of the coach profile; the first save that stores a value creates the profile
    (`in_progress`). Values are validated but nothing is required until completion, and saving never
    completes onboarding. A field outside `CoachProfileUpdateRequest` (including ids, the owner and the
    completion time) is rejected with `422 validation_error` and code `invalid` under that field name; a
    repeated selection value is rejected with `invalid`. An invalid request changes nothing. Saving does not
    require completed account registration.
    """,
    security: @security,
    request_body:
      {"Fields to save", "application/json", Schemas.CoachProfileUpdateRequest, required: true},
    responses: [
      ok: @profile_response,
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  # Only the JSON body is the request; query parameters are not profile fields.
  def update(conn, _params) do
    with {:ok, profile} <- Coaches.update_profile(conn.assigns.current_user, conn.body_params) do
      render_profile(conn, profile)
    end
  end

  operation :complete_onboarding,
    operation_id: "completeMyCoachOnboarding",
    summary: "Complete Coach onboarding",
    description: """
    Records that Coach onboarding is complete, after checking every requirement on the server. While any
    required field is missing the response is `422 validation_error` with a `required` field code per missing
    field, and nothing changes. Completion also requires completed shared account registration
    (`completeAccountRegistration`): until then the error carries `account_registration` with code `required`.
    Completing again returns the profile with its original `completed_at`. Completion grants no access to
    other users' data.
    """,
    security: @security,
    responses: [
      ok: @profile_response,
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def complete_onboarding(conn, _params) do
    with {:ok, profile} <- Coaches.complete_onboarding(conn.assigns.current_user) do
      render_profile(conn, profile)
    end
  end

  # Personal profile data is never stored by shared caches or the browser.
  defp render_profile(conn, profile) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> render(:show, profile: profile)
  end
end
