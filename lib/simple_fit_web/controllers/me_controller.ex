defmodule SimpleFitWeb.MeController do
  @moduledoc """
  The authenticated viewer (ADR 0010). `GET /api/me` returns only what the
  user record holds today; profiles, workspace memberships and other
  capabilities will be added as sibling fields by the tickets that create
  them, without changing `user`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFitWeb.{ApiSpec, Schemas}

  tags ["Auth"]

  operation :show,
    operation_id: "getCurrentUser",
    summary: "The authenticated user",
    description:
      "Returns the user of the session behind the bearer access token. Sign-in identities, provider data and session secrets are never included.",
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"The current user", "application/json", Schemas.CurrentUserResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, _params) do
    render(conn, :show, user: conn.assigns.current_user)
  end
end
