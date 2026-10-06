defmodule SimpleFitWeb.SessionController do
  @moduledoc """
  Session refresh and logout (ADR 0010). Creating a session belongs to the
  authentication flows (email, Google, Apple), which call
  `SimpleFit.Accounts.create_session/1` and render with `SessionJSON`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Response, Schema}
  alias SimpleFit.Accounts
  alias SimpleFitWeb.{APIError, ApiSpec, Schemas, SessionTransport}
  alias SimpleFitWeb.Plugs.Authenticate

  tags ["Auth"]

  @csrf_parameter %Parameter{
    name: "x-simplefit-csrf",
    in: :header,
    required: false,
    description:
      "Required (value `1`) when the refresh token is sent as the web cookie, together with an allow-listed `Origin`.",
    schema: %Schema{type: :string, enum: ["1"]}
  }

  @set_cookie_header %Header{
    description:
      "Cookie transport only: the rotated refresh token (`HttpOnly; Secure; SameSite=Strict; Path=/api/auth`) or its deletion.",
    schema: %Schema{type: :string}
  }

  operation :refresh,
    operation_id: "refreshSession",
    summary: "Rotate the refresh token and get a new access token",
    description: """
    Consumes the refresh token and issues a new access token and a new refresh token for the same
    session. A refresh token works once: presenting a consumed token again revokes its session.

    **Transport** (exactly one):

    * Mobile/body: send `{"refresh_token": "sfr_..."}`; the new refresh token is returned in the body.
    * Web/cookie: send the `__Secure-sf_refresh` cookie (no body token), an allow-listed `Origin` and
      `x-simplefit-csrf: 1`; the new refresh token is set as the cookie and omitted from the body.

    Every invalid, expired, revoked or reused token yields the same `401 unauthorized` (and, for the
    cookie transport, clears the cookie).
    """,
    parameters: [@csrf_parameter],
    request_body:
      {"Refresh token (body transport only)", "application/json", Schemas.RefreshSessionRequest,
       required: false},
    security: [%{}, %{"refreshCookie" => []}],
    responses: [
      ok:
        {"New session credentials", "application/json", Schemas.SessionTokens,
         headers: %{"set-cookie" => @set_cookie_header}},
      bad_request: ApiSpec.error_response("bad_request"),
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def refresh(conn, _params) do
    case SessionTransport.fetch_refresh_token(conn) do
      {:ok, transport, token, conn} -> refresh_with(conn, transport, token)
      {:error, :ambiguous, conn} -> APIError.send_error(conn, "bad_request")
      {:error, :missing, conn} -> Authenticate.unauthorized(conn)
    end
  end

  defp refresh_with(conn, transport, token) do
    with :ok <- csrf_check(conn, transport),
         {:ok, credentials} <- Accounts.refresh_session(token) do
      conn
      |> SessionTransport.put_refresh_token(
        transport,
        credentials.refresh_token,
        credentials.refresh_token_expires_at
      )
      |> render(:show, credentials: credentials, transport: transport)
    else
      {:error, :forbidden} ->
        APIError.send_error(conn, "forbidden")

      {:error, :unauthorized} ->
        conn
        |> maybe_clear_cookie(transport)
        |> Authenticate.unauthorized()
    end
  end

  operation :logout,
    operation_id: "logout",
    summary: "Log out of the current session",
    description: """
    Revokes the session identified by the request's credential: the bearer access token, the refresh
    token in the body, or the web refresh cookie (cookie requests need an allow-listed `Origin` and
    `x-simplefit-csrf: 1`). The refresh cookie is always cleared.

    Idempotent: the response is `204` whether the session was active, already revoked or not
    identifiable, so it reveals nothing about any session. A revoked session can no longer refresh or
    access authenticated endpoints.
    """,
    parameters: [@csrf_parameter],
    request_body:
      {"Refresh token (optional, body transport)", "application/json",
       Schemas.RefreshSessionRequest, required: false},
    security: [%{}, %{"bearerAuth" => []}, %{"refreshCookie" => []}],
    responses: [
      no_content: %Response{
        description: "Logged out (or nothing to log out)",
        headers: %{"set-cookie" => @set_cookie_header}
      },
      forbidden: ApiSpec.error_response("forbidden"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def logout(conn, _params) do
    {refresh, conn} = logout_refresh_token(conn)

    case logout_csrf_check(conn, refresh) do
      :ok ->
        for credential <- logout_credentials(conn, refresh),
            do: :ok = Accounts.revoke_session(credential)

        conn
        |> SessionTransport.clear_refresh_cookie()
        |> send_resp(:no_content, "")

      {:error, :forbidden} ->
        APIError.send_error(conn, "forbidden")
    end
  end

  defp logout_refresh_token(conn) do
    case SessionTransport.fetch_refresh_token(conn) do
      {:ok, transport, token, conn} -> {[{transport, token}], conn}
      {:error, :missing, conn} -> {[], conn}
      {:error, :ambiguous, conn} -> {ambiguous_tokens(conn), conn}
    end
  end

  # Logging out with both a cookie and a body token revokes both sessions.
  defp ambiguous_tokens(conn) do
    [
      {:cookie, conn.req_cookies[SessionTransport.cookie_name()]},
      {:body, conn.body_params["refresh_token"]}
    ]
  end

  defp logout_csrf_check(conn, refresh) do
    if Enum.any?(refresh, &match?({:cookie, _token}, &1)),
      do: SessionTransport.verify_cookie_request(conn),
      else: :ok
  end

  defp logout_credentials(conn, refresh) do
    access =
      case Authenticate.bearer_token(conn) do
        {:ok, token} -> [{:access, token}]
        :error -> []
      end

    access ++ for {_transport, token} <- refresh, is_binary(token), do: {:refresh, token}
  end

  defp csrf_check(conn, :cookie), do: SessionTransport.verify_cookie_request(conn)
  defp csrf_check(_conn, :body), do: :ok

  defp maybe_clear_cookie(conn, :cookie), do: SessionTransport.clear_refresh_cookie(conn)
  defp maybe_clear_cookie(conn, :body), do: conn
end
