defmodule SimpleFitWeb.PasswordAuthController do
  @moduledoc """
  The optional password credential (SF-157, ADR 0012 amendment): sign-in with an email
  identity's address and password, setting or resetting a password with an emailed
  code, and changing it while signed in. Sessions are SF-20 sessions, rendered by
  `SessionJSON` through `SessionTransport`.

  Signing in authenticates the user only: it creates no operator and grants nothing.
  The public endpoints are rate limited (`429 rate_limited` with `retry-after`) and
  never reveal whether an account or a password exists.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Accounts
  alias SimpleFitWeb.{APIError, ApiSpec, ClientIP, Schemas, SessionJSON, SessionTransport}

  tags ["Auth"]

  @csrf_parameter %Parameter{
    name: "x-simplefit-csrf",
    in: :header,
    required: false,
    description:
      "Required (value `1`) with `refresh_token_transport: cookie`, together with an allow-listed `Origin`.",
    schema: %Schema{type: :string, enum: ["1"]}
  }

  @set_cookie_header %Header{
    description:
      "Cookie transport only: the refresh token (`HttpOnly; Secure; SameSite=Strict; Path=/api/auth`).",
    schema: %Schema{type: :string}
  }

  @retry_after_header %Header{
    description: "Seconds until another request is accepted (with `429 rate_limited`).",
    schema: %Schema{type: :integer}
  }

  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{"retry-after" => @retry_after_header}}

  operation :sign_in,
    operation_id: "signInWithPassword",
    summary: "Sign in with an email address and password",
    description: """
    Starts an SF-20 session for the user whose email identity has this address, when the password is that
    user's. Authentication only: it creates no account, operator or permission, and Control Plane access is still
    decided by every operator endpoint.

    * `invalid_credentials` - the same answer, after the same work, for a wrong password, an unknown address and
      an account without a password.
    * `account_suspended` - the password is right but the account is suspended.
    * `rate_limited` - too many attempts from this client or for this address.
    """,
    parameters: [@csrf_parameter],
    request_body:
      {"Email address and password", "application/json", Schemas.PasswordSignInRequest,
       required: true},
    responses: [
      ok:
        {"Session credentials", "application/json", Schemas.SessionTokens,
         headers: %{"set-cookie" => @set_cookie_header}},
      forbidden: ApiSpec.error_response("account_suspended"),
      unprocessable_entity: ApiSpec.error_response("invalid_credentials"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def sign_in(conn, params) do
    with {:ok, transport} <- transport(conn, params),
         {:ok, credentials} <-
           Accounts.password_sign_in(params["email"], params["password"], client_ip(conn)) do
      session(conn, transport, credentials)
    end
    |> respond(conn)
  end

  operation :request_reset,
    operation_id: "requestPasswordReset",
    summary: "Send a code to set or reset a password",
    description: """
    If the address is an account's email address, sends a 6-digit code that sets a new password for that account
    (also the first one). The response is the same for every well-formed address and never reveals whether an
    account exists. Requesting again replaces the previous code.
    """,
    request_body: {"Email address", "application/json", Schemas.EmailCodeRequest, required: true},
    responses: [
      accepted: {"Password code requested", "application/json", Schemas.PasswordResetAccepted},
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def request_reset(conn, params) do
    with {:ok, result} <- Accounts.request_password_reset(params["email"], client_ip(conn)) do
      conn |> put_status(:accepted) |> render(:reset_accepted, result: result)
    end
    |> respond(conn)
  end

  operation :confirm_reset,
    operation_id: "confirmPasswordReset",
    summary: "Set or reset a password with its code",
    description: """
    Sets the password of the account whose email address received the code, replacing any previous password, and
    signs that account out everywhere. Signs nobody in: sign in with the new password afterwards.

    * `code_invalid` - wrong code. After 5 wrong codes the code stops working.
    * `code_expired` - the code expired, was replaced, was already used or stopped working: request a new one.
    * `validation_error` - the new password is shorter than 12 or longer than 128 characters, or is the email
      address. Checked before the code, so a bad password doesn't use up the code.
    """,
    request_body:
      {"Email address, code and new password", "application/json",
       Schemas.PasswordResetConfirmRequest, required: true},
    responses: [
      no_content: "Password set; every session of the account was signed out",
      unprocessable_entity: ApiSpec.error_response("code_invalid"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def confirm_reset(conn, params) do
    with :ok <-
           Accounts.reset_password(
             params["email"],
             params["code"],
             params["password"],
             client_ip(conn)
           ) do
      send_resp(conn, :no_content, "")
    end
    |> respond(conn)
  end

  operation :status,
    operation_id: "getMyPasswordStatus",
    summary: "Whether the viewer has a password",
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"Password status", "application/json", Schemas.PasswordStatus},
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def status(conn, _params) do
    render(conn, :status, password_set: Accounts.password_set?(conn.assigns.current_user))
  end

  operation :change,
    operation_id: "changeMyPassword",
    summary: "Change the viewer's password",
    description: """
    Replaces the viewer's password, given the current one, and signs out every other session of the account; this
    session stays signed in.

    * `invalid_credentials` - the current password is not correct.
    * `password_not_set` - the account has no password yet: set one with a code (`requestPasswordReset`).
    * `conflict` - the password changed meanwhile (another change or a reset): try again.
    """,
    security: [%{"bearerAuth" => []}],
    request_body:
      {"Current and new password", "application/json", Schemas.PasswordChangeRequest,
       required: true},
    responses: [
      no_content: "Password changed; every other session was signed out",
      unauthorized: ApiSpec.error_response("unauthorized"),
      conflict: ApiSpec.error_response("password_not_set"),
      unprocessable_entity: ApiSpec.error_response("invalid_credentials"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def change(conn, params) do
    with :ok <-
           Accounts.change_password(
             conn.assigns.current_user,
             conn.assigns.current_session,
             params["current_password"],
             params["password"]
           ) do
      send_resp(conn, :no_content, "")
    end
    |> respond(conn)
  end

  ## Helpers

  defp client_ip(conn), do: ClientIP.limit_key(conn)

  # The refresh token transport of a new session (ADR 0010). The cookie transport
  # carries an ambient credential, so it needs the CSRF proof before anything is
  # verified.
  defp transport(conn, params) do
    case Map.get(params, "refresh_token_transport", "body") do
      "body" ->
        {:ok, :body}

      "cookie" ->
        with :ok <- SessionTransport.verify_cookie_request(conn), do: {:ok, :cookie}

      _other ->
        {:error, :bad_transport}
    end
  end

  defp session(conn, transport, credentials) do
    conn
    |> SessionTransport.put_refresh_token(
      transport,
      credentials.refresh_token,
      credentials.refresh_token_expires_at
    )
    |> put_view(SessionJSON)
    |> render(:show, credentials: credentials, transport: transport)
  end

  defp respond(%Plug.Conn{} = conn, _original), do: conn

  defp respond({:error, {:rate_limited, retry_after}}, conn),
    do: APIError.send_error(conn, "rate_limited", retry_after: retry_after)

  defp respond({:error, reason}, conn)
       when reason in [
              :invalid_credentials,
              :password_not_set,
              :account_suspended,
              :code_invalid,
              :code_expired,
              :forbidden,
              :conflict,
              :unauthorized
            ],
       do: APIError.send_error(conn, Atom.to_string(reason))

  defp respond({:error, :bad_transport}, conn), do: APIError.send_error(conn, "bad_request")

  defp respond({:error, _reason} = error, conn),
    do: SimpleFitWeb.FallbackController.call(conn, error)
end
