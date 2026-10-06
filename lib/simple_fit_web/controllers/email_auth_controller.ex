defmodule SimpleFitWeb.EmailAuthController do
  @moduledoc """
  Passwordless email authentication (ADR 0012): registration with email
  ownership verification (E01: code or link) and sign-in with an emailed
  code (E17). Sessions are SF-20 sessions, rendered by `SessionJSON`
  through `SessionTransport`.

  Every endpoint is public, rate limited (`429 rate_limited` with
  `retry-after`) and answers code requests the same whether or not an
  account exists.
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

  ## Registration

  operation :request_registration,
    operation_id: "requestEmailRegistration",
    summary: "Start registration: send an email verification code (E01)",
    description: """
    Starts the email ownership verification of a new account and sends E01 (a 6-digit code and a verification
    link). Requesting again for the same address replaces the previous code, link and registration token.

    The response is the same for every well-formed address, including addresses that already have an account
    (no email is sent then, and nothing is created): it never reveals whether an account exists. Sign-up never
    turns into sign-in.
    """,
    request_body: {"Email address", "application/json", Schemas.EmailCodeRequest, required: true},
    responses: [
      accepted: {"Verification requested", "application/json", Schemas.EmailRegistrationAccepted},
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def request_registration(conn, params) do
    with {:ok, result} <- Accounts.request_email_registration(params["email"], client_ip(conn)) do
      conn |> put_status(:accepted) |> render(:registration_accepted, result: result)
    end
    |> respond(conn)
  end

  operation :verify_registration,
    operation_id: "verifyEmailRegistrationCode",
    summary: "Verify a registration with its code and start its session",
    description: """
    Verifies the email of a registration with the 6-digit code from E01. Only the client that started the
    registration can do this: it sends its `registration_token`. On success the account exists and this client
    receives the registration's one SF-20 session.

    * `code_invalid` - wrong code. After 5 wrong codes the code stops working.
    * `code_expired` - the code expired, was replaced, was already used or stopped working: request a new one.
    * `verified_elsewhere` - the email was verified through the E01 link (possibly on another device). The link
      never signs anyone in: this client must sign in with an email sign-in code.
    * `conflict` - the address already has an account.
    """,
    parameters: [@csrf_parameter],
    request_body:
      {"Registration token and code", "application/json", Schemas.EmailRegistrationCodeRequest,
       required: true},
    responses: [
      ok:
        {"Session credentials", "application/json", Schemas.SessionTokens,
         headers: %{"set-cookie" => @set_cookie_header}},
      forbidden: ApiSpec.error_response("forbidden"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("code_invalid"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def verify_registration(conn, params) do
    with {:ok, transport} <- transport(conn, params),
         {:ok, credentials} <-
           Accounts.verify_email_registration_code(
             params["registration_token"],
             params["code"],
             client_ip(conn)
           ) do
      session(conn, transport, credentials)
    end
    |> respond(conn)
  end

  operation :registration_status,
    operation_id: "getEmailRegistrationStatus",
    summary: "The state of a registration",
    description: """
    For the client that started a registration (it sends its `registration_token`). `verified_elsewhere` means
    the E01 link verified the email: this client is not signed in and must request an email sign-in code.
    """,
    request_body:
      {"Registration token", "application/json", Schemas.EmailRegistrationStatusRequest,
       required: true},
    responses: [
      ok: {"Registration state", "application/json", Schemas.EmailRegistrationStatus},
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def registration_status(conn, params) do
    with {:ok, status} <-
           Accounts.email_registration_status(params["registration_token"], client_ip(conn)) do
      render(conn, :registration_status, status: status)
    end
    |> respond(conn)
  end

  operation :verify_link,
    operation_id: "verifyEmailLink",
    summary: "Verify an email with the E01 link",
    description: """
    Verifies the email of a registration with the token from the E01 link fragment
    (`/verify-email#token=...`), from any device. It never signs anyone in: no session is created, neither for
    this browser nor for the device that started the registration.

    `code_expired` - the link expired, was replaced by a newer request or stopped working.
    """,
    request_body:
      {"Link token", "application/json", Schemas.EmailVerificationLinkRequest, required: true},
    responses: [
      ok: {"Email verified", "application/json", Schemas.EmailVerificationLinkResult},
      unprocessable_entity: ApiSpec.error_response("code_expired"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def verify_link(conn, params) do
    with {:ok, status} <- Accounts.verify_email_link(params["token"], client_ip(conn)) do
      render(conn, :link_result, status: status)
    end
    |> respond(conn)
  end

  ## Sign-in

  operation :request_sign_in,
    operation_id: "requestEmailSignIn",
    summary: "Send an email sign-in code (E17)",
    description: """
    If the address has an account, sends E17 with a 6-digit sign-in code. The response is the same for every
    well-formed address and never reveals whether an account exists. Requesting again replaces the previous
    code.
    """,
    request_body: {"Email address", "application/json", Schemas.EmailCodeRequest, required: true},
    responses: [
      accepted: {"Sign-in code requested", "application/json", Schemas.EmailSignInAccepted},
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def request_sign_in(conn, params) do
    with {:ok, result} <- Accounts.request_email_sign_in(params["email"], client_ip(conn)) do
      conn |> put_status(:accepted) |> render(:sign_in_accepted, result: result)
    end
    |> respond(conn)
  end

  operation :verify_sign_in,
    operation_id: "verifyEmailSignInCode",
    summary: "Sign in with an email sign-in code",
    description: """
    Verifies the 6-digit code from E17 and starts an SF-20 session.

    * `code_invalid` - wrong code. After 5 wrong codes the code stops working.
    * `code_expired` - the code expired, was replaced, was already used or stopped working: request a new one.
    """,
    parameters: [@csrf_parameter],
    request_body:
      {"Email address and code", "application/json", Schemas.EmailSignInCodeRequest,
       required: true},
    responses: [
      ok:
        {"Session credentials", "application/json", Schemas.SessionTokens,
         headers: %{"set-cookie" => @set_cookie_header}},
      forbidden: ApiSpec.error_response("forbidden"),
      unprocessable_entity: ApiSpec.error_response("code_invalid"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def verify_sign_in(conn, params) do
    with {:ok, transport} <- transport(conn, params),
         {:ok, credentials} <-
           Accounts.verify_email_sign_in_code(params["email"], params["code"], client_ip(conn)) do
      session(conn, transport, credentials)
    end
    |> respond(conn)
  end

  ## Helpers

  defp client_ip(conn), do: ClientIP.get(conn)

  # The refresh token transport of a new session (ADR 0010). The cookie
  # transport carries an ambient credential, so it needs the CSRF proof
  # before anything is verified.
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

  # Expected outcomes map to catalogued codes; changesets and anything else
  # go to the fallback controller.
  defp respond(%Plug.Conn{} = conn, _original), do: conn

  defp respond({:error, {:rate_limited, retry_after}}, conn),
    do: APIError.send_error(conn, "rate_limited", retry_after: retry_after)

  defp respond({:error, reason}, conn)
       when reason in [:code_invalid, :code_expired, :verified_elsewhere, :forbidden, :conflict],
       do: APIError.send_error(conn, Atom.to_string(reason))

  defp respond({:error, :bad_transport}, conn), do: APIError.send_error(conn, "bad_request")

  defp respond({:error, _reason} = error, conn),
    do: SimpleFitWeb.FallbackController.call(conn, error)
end
