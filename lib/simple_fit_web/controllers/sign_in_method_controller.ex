defmodule SimpleFitWeb.SignInMethodController do
  @moduledoc """
  The viewer's sign-in methods (SF-161): how the account can be signed in to,
  for Settings · Sign-in & security. The user comes from the access token
  only; no user or identity id is accepted. The rules live in
  `SimpleFit.Accounts`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFit.Accounts
  alias SimpleFitWeb.{ApiSpec, Schemas}

  tags ["Account"]

  operation :index,
    operation_id: "listMySignInMethods",
    summary: "My sign-in methods",
    description: """
    How the viewer's account can be signed in to, oldest first (within the same second, by provider): every email address whose ownership was proven
    with a code, and every Google or Apple account that signed in to it. An email method carries its address; a
    Google or Apple method carries only its provider and when it was added (the provider's account id is never
    returned, and an email a provider reported is never listed). Credentials are never included.
    """,
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"The viewer's sign-in methods", "application/json", Schemas.SignInMethodList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, _params) do
    render(conn, :index, methods: Accounts.list_sign_in_methods(conn.assigns.current_user))
  end
end
