defmodule SimpleFitWeb.SessionTransport do
  @moduledoc """
  How session credentials travel between the API and its clients (ADR 0010).

  One session model, two transports for the long-lived refresh token:

    * **Body** (mobile and other non-browser clients): the refresh token is
      sent and returned in JSON (`refresh_token`). The client keeps it in
      platform secure storage.
    * **Cookie** (web): the refresh token lives only in an `HttpOnly`,
      `SameSite=Strict` cookie scoped to `/api/auth`, `Secure` (and named
      `__Secure-sf_refresh`) unless the environment opts out for plain-http
      development. JavaScript never sees it, so it never needs localStorage.

  A request uses one transport: sending the token both ways is rejected
  (`bad_request`), so a response never mixes them. The access token is
  always returned in the JSON body and sent back as `Authorization: Bearer`.

  Cookie requests carry an ambient credential, so they must prove they come
  from the SimpleFit web app (`verify_cookie_request/1`): an `Origin` on the
  CORS allow-list and the `x-simplefit-csrf: 1` header, which a cross-site
  form cannot send and a cross-site script cannot send without a CORS
  preflight that the API refuses.
  """

  alias Plug.Conn
  alias SimpleFitWeb.CORS

  @cookie_path "/api/auth"
  @csrf_header "x-simplefit-csrf"

  @type transport :: :cookie | :body

  @doc "The header (value `1`) that cookie-transport requests must carry."
  @spec csrf_header() :: String.t()
  def csrf_header, do: @csrf_header

  @doc "Name of the refresh cookie in this environment."
  @spec cookie_name() :: String.t()
  def cookie_name, do: if(secure_cookie?(), do: "__Secure-sf_refresh", else: "sf_refresh")

  @doc """
  The refresh token of a request and its transport.

    * `{:ok, transport, token, conn}`
    * `{:error, :missing, conn}` when neither the cookie nor `refresh_token`
      is present
    * `{:error, :ambiguous, conn}` when both are present
  """
  @spec fetch_refresh_token(Conn.t()) ::
          {:ok, transport(), term(), Conn.t()} | {:error, :missing | :ambiguous, Conn.t()}
  def fetch_refresh_token(conn) do
    conn = Conn.fetch_cookies(conn, signed: [], encrypted: [])
    cookie = conn.req_cookies[cookie_name()]
    body = body_token(conn.body_params)

    case {cookie, body} do
      {nil, nil} -> {:error, :missing, conn}
      {nil, token} -> {:ok, :body, token, conn}
      {token, nil} -> {:ok, :cookie, token, conn}
      {_cookie, _body} -> {:error, :ambiguous, conn}
    end
  end

  defp body_token(%{"refresh_token" => token}), do: token
  defp body_token(_params), do: nil

  @doc """
  CSRF boundary for cookie-transport requests: an allow-listed `Origin` and
  `x-simplefit-csrf: 1`.
  """
  @spec verify_cookie_request(Conn.t()) :: :ok | {:error, :forbidden}
  def verify_cookie_request(conn) do
    origin = Conn.get_req_header(conn, "origin")
    csrf = Conn.get_req_header(conn, @csrf_header)

    case {origin, csrf} do
      {[origin], ["1"]} ->
        if String.downcase(origin) in CORS.allowed_origins(), do: :ok, else: {:error, :forbidden}

      _missing_or_repeated ->
        {:error, :forbidden}
    end
  end

  @doc "Sets the refresh cookie for cookie-transport responses (no-op for body)."
  @spec put_refresh_token(Conn.t(), transport(), String.t(), DateTime.t()) :: Conn.t()
  def put_refresh_token(conn, :body, _token, _expires_at), do: conn

  def put_refresh_token(conn, :cookie, token, expires_at) do
    max_age = max(DateTime.diff(expires_at, DateTime.utc_now()), 0)
    Conn.put_resp_cookie(conn, cookie_name(), token, cookie_options(max_age: max_age))
  end

  @doc "Expires the refresh cookie in the browser."
  @spec clear_refresh_cookie(Conn.t()) :: Conn.t()
  def clear_refresh_cookie(conn) do
    Conn.delete_resp_cookie(conn, cookie_name(), cookie_options([]))
  end

  defp cookie_options(extra) do
    [
      http_only: true,
      secure: secure_cookie?(),
      same_site: "Strict",
      path: @cookie_path
    ] ++ extra
  end

  defp secure_cookie? do
    Application.get_env(:simple_fit, __MODULE__, [])[:secure_cookie] != false
  end
end
