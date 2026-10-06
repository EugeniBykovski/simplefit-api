defmodule SimpleFitWeb.GoogleAuthController do
  @moduledoc """
  Google sign-in (ADR 0013): exchanges a Google ID token for an SF-20
  session. One endpoint for sign-up and sign-in: an unknown Google account is
  created, a known one signed in.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Accounts
  alias SimpleFitWeb.{APIError, ApiSpec, ClientIP, Schemas, SessionJSON, SessionTransport}
  alias SimpleFitWeb.Plugs.Authenticate

  tags ["Auth"]

  operation :authenticate,
    operation_id: "authenticateWithGoogle",
    summary: "Sign in (or sign up) with a Google ID token",
    description: """
    Verifies the Google ID token (RS256 signature with Google's keys, issuer, audience, authorized party, expiry,
    subject) and starts a SimpleFit session. The Google token is never a SimpleFit credential and is not stored.

    The Google account is identified only by its subject (`sub`): an unknown one creates a new account
    (`account: created`), a known one signs in (`account: existing`). Accounts are never linked by email.

    * `unauthorized` - the token is not a valid Google ID token for SimpleFit (no detail is given).
    * `service_unavailable` - Google's signing keys cannot be obtained or Google sign-in is not configured.
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
      {"Google ID token", "application/json", Schemas.GoogleAuthRequest, required: true},
    responses: [
      ok:
        {"Session credentials", "application/json", Schemas.GoogleAuthResponse,
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
           Accounts.authenticate_with_google(params["id_token"], ClientIP.get(conn)) do
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
