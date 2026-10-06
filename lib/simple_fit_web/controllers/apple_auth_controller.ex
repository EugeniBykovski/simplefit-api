defmodule SimpleFitWeb.AppleAuthController do
  @moduledoc """
  Sign in with Apple (ADR 0014): exchanges an Apple identity token (and the
  raw nonce of its request) for an SF-20 session. One endpoint for sign-up and
  sign-in, web and iOS: an unknown Apple account is created, a known one
  signed in. There is no callback and no authorization-code exchange.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Accounts
  alias SimpleFitWeb.{APIError, ApiSpec, ClientIP, Schemas, SessionJSON, SessionTransport}
  alias SimpleFitWeb.Plugs.Authenticate

  tags ["Auth"]

  operation :authenticate,
    operation_id: "authenticateWithApple",
    summary: "Sign in (or sign up) with an Apple identity token",
    description: """
    Verifies the Apple identity token (RS256 signature with Apple's keys, issuer, audience, expiry, subject, and
    the nonce: the token's `nonce` must be the lowercase hex SHA-256 of the raw `nonce` sent here) and starts a
    SimpleFit session. Apple credentials are never SimpleFit credentials and are not stored.

    The Apple account is identified only by its subject (`sub`): an unknown one creates a new account
    (`account: created`), a known one signs in (`account: existing`). Email (including private relay
    addresses) and name are never read; accounts are never linked by email.

    * `unauthorized` - the token is not a valid Apple identity token for SimpleFit (no detail is given).
    * `service_unavailable` - Apple's signing keys cannot be obtained or Sign in with Apple is not configured.
    """,
    parameters: [
      %Parameter{
        name: "x-simplefit-csrf",
        in: :header,
        required: false,
        description:
          "Required (value `1`) with `refresh_token_transport: cookie`, together with an allow-listed `Origin`.",
        schema: %Schema{type: :string, enum: ["1"]}
      }
    ],
    request_body:
      {"Apple identity token and raw nonce", "application/json", Schemas.AppleAuthRequest,
       required: true},
    responses: [
      ok:
        {"Session credentials", "application/json", Schemas.AppleAuthResponse,
         headers: %{
           "set-cookie" => %Header{
             description:
               "Cookie transport only: the refresh token (`HttpOnly; Secure; SameSite=Strict; Path=/api/auth`).",
             schema: %Schema{type: :string}
           }
         }},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests:
        {"Too many requests", "application/json", Schemas.ErrorResponse,
         headers: %{
           "retry-after" => %Header{
             description: "Seconds until another request is accepted.",
             schema: %Schema{type: :integer}
           }
         }},
      service_unavailable: ApiSpec.error_response("service_unavailable"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def authenticate(conn, params) do
    with {:ok, transport} <- transport(conn, params),
         {:ok, %{credentials: credentials, account: account}} <-
           Accounts.authenticate_with_apple(
             params["id_token"],
             params["nonce"],
             ClientIP.get(conn)
           ) do
      conn
      |> SessionTransport.put_refresh_token(
        transport,
        credentials.refresh_token,
        credentials.refresh_token_expires_at
      )
      |> json(
        SessionJSON.show(%{credentials: credentials, transport: transport})
        |> Map.put(:account, Atom.to_string(account))
      )
    end
    |> respond(conn)
  end

  # The cookie transport carries an ambient credential, so its CSRF proof is
  # checked before the token is verified (ADR 0010).
  defp transport(conn, params) do
    case Map.get(params, "refresh_token_transport", "body") do
      "body" ->
        {:ok, :body}

      "cookie" ->
        with :ok <- SessionTransport.verify_cookie_request(conn), do: {:ok, :cookie}

      _other ->
        {:error, transport_error()}
    end
  end

  defp transport_error do
    {%{}, %{refresh_token_transport: :string}}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:refresh_token_transport, "is invalid", validation: :inclusion)
  end

  defp respond(%Plug.Conn{} = conn, _original), do: conn

  defp respond({:error, {:rate_limited, retry_after}}, conn),
    do: APIError.send_error(conn, "rate_limited", retry_after: retry_after)

  defp respond({:error, :unauthorized}, conn), do: Authenticate.unauthorized(conn)
  defp respond({:error, :unavailable}, conn), do: APIError.send_error(conn, "service_unavailable")
  defp respond({:error, :forbidden}, conn), do: APIError.send_error(conn, "forbidden")

  defp respond({:error, _reason} = error, conn),
    do: SimpleFitWeb.FallbackController.call(conn, error)
end
