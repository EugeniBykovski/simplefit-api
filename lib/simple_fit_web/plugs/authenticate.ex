defmodule SimpleFitWeb.Plugs.Authenticate do
  @moduledoc """
  Authenticates API requests with a SimpleFit access token (ADR 0010).

  Reads `Authorization: Bearer sfa_...`, verifies the signature and expiry,
  then loads the session (not revoked, not expired) and its one user. On
  success it assigns `:current_user` and `:current_session`. Any failure is
  the same `401 unauthorized` envelope with `www-authenticate: Bearer`,
  whether the token is missing, malformed, expired, revoked or unknown.

  Only SimpleFit access tokens are accepted: refresh tokens and provider
  tokens are never bearer credentials.
  """

  @behaviour Plug

  alias Plug.Conn
  alias SimpleFit.Accounts
  alias SimpleFitWeb.APIError

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, %{user: user, session: session}} <- Accounts.authenticate_access_token(token) do
      conn
      |> Conn.assign(:current_user, user)
      |> Conn.assign(:current_session, session)
    else
      _unauthenticated -> unauthorized(conn)
    end
  end

  @doc """
  The bearer token of a request: exactly one `Authorization` header with the
  `Bearer` scheme (case-insensitive). Anything else is `:error`.
  """
  @spec bearer_token(Conn.t()) :: {:ok, String.t()} | :error
  def bearer_token(conn) do
    with [header] <- Conn.get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token when token != "" <- String.trim(token) do
      {:ok, token}
    else
      _missing_or_malformed -> :error
    end
  end

  @doc "Sends the canonical `401 unauthorized` with `www-authenticate: Bearer`."
  @spec unauthorized(Conn.t()) :: Conn.t()
  def unauthorized(conn) do
    conn
    |> Conn.put_resp_header("www-authenticate", "Bearer")
    |> APIError.send_error("unauthorized")
  end
end
