defmodule SimpleFitWeb.AccountProfileController do
  @moduledoc """
  The authenticated user's shared account registration: basics and consents
  (ADR 0016). Every action acts on the session's own user; the rules live in
  `SimpleFit.Accounts`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.AccountProfile
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Account"]

  @security [%{"bearerAuth" => []}]
  @response {"The account registration state", "application/json", Schemas.AccountProfileResponse}

  operation :show,
    operation_id: "getMyAccountProfile",
    summary: "My account registration state",
    description: """
    Returns the shared account registration: basics, consent state and the missing requirements. Before
    registration has started the response is still `200` with `status: not_started`; reading creates nothing.
    Authentication never completes registration, whatever the sign-in method.
    """,
    security: @security,
    responses: [
      ok: @response,
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, _params) do
    render(conn, :show,
      registration: Accounts.get_account_registration(conn.assigns.current_user)
    )
  end

  operation :update,
    operation_id: "updateMyAccountProfile",
    summary: "Save account registration progress",
    description: """
    Saves any subset of the basics and consent decisions. The first save that persists something creates the
    account profile (`in_progress`); a save with nothing to persist creates nothing. Required consents are
    recorded with their current document version; product news can be subscribed and withdrawn. An invalid
    request changes nothing.
    """,
    security: @security,
    request_body:
      {"Fields and decisions to save", "application/json", Schemas.AccountProfileUpdateRequest,
       required: true},
    responses: [
      ok: @response,
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update(conn, params) do
    attrs = Map.take(params, Enum.map(AccountProfile.editable_fields(), &to_string/1))

    with {:ok, registration} <-
           Accounts.update_account_registration(conn.assigns.current_user, attrs) do
      render(conn, :show, registration: registration)
    end
  end

  operation :complete_registration,
    operation_id: "completeAccountRegistration",
    summary: "Complete account registration",
    description: """
    Records that shared account registration is complete, after checking every requirement on the server: full
    name, a date of birth at least 16 years ago, and current acceptance of the Terms of Service and the Privacy
    Policy. While anything is missing the response is `422 validation_error` with a `required` field code per
    missing item (`full_name`, `date_of_birth`, `terms`, `privacy`) and nothing changes. Completion is
    permanent: completing again returns the state with the original `completed_at`, and a later Terms or
    Privacy version change does not reopen it (`consents.*.current` reports it instead).
    """,
    security: @security,
    responses: [
      ok: @response,
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def complete_registration(conn, _params) do
    with {:ok, registration} <- Accounts.complete_account_registration(conn.assigns.current_user) do
      render(conn, :show, registration: registration)
    end
  end
end
