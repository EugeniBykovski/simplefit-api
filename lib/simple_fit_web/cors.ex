defmodule SimpleFitWeb.CORS do
  @moduledoc """
  Cross-origin policy of the API (SF-6). The API owns it; browser clients
  never proxy around it. See docs/architecture/adr/0007-cors-policy.md.

    * **Explicit allow-list.** Only origins listed in
      `config :simple_fit, SimpleFitWeb.CORS, allowed_origins: [...]` (from
      `CORS_ALLOWED_ORIGINS` at runtime) receive CORS headers. There is no
      wildcard; unknown origins get none, so browsers block the response.
    * **Preflight.** `OPTIONS` with `access-control-request-method` is answered
      here with 204 when the origin, method and requested headers are allowed,
      and with the `forbidden` error envelope (no CORS headers) otherwise.
    * **Credentials only for the refresh cookie.** Clients authenticate with
      bearer tokens. `access-control-allow-credentials: true` is sent only for
      allowed origins on the endpoints that read or set the web refresh
      cookie (`POST /api/auth/session/refresh`, `POST /api/auth/logout`,
      ADR 0010; `POST /api/auth/email/registrations/verify`,
      `POST /api/auth/email/sign-in/verify`, ADR 0012;
      `POST /api/auth/google`, ADR 0013); every other path stays
      credential-free.
    * `x-request-id` is exposed so browser clients can read it for support.

  Requests without an `Origin` header (mobile apps, server-to-server, curl)
  are not affected.
  """

  @behaviour Plug

  alias Plug.Conn
  alias SimpleFitWeb.APIError

  @allowed_methods ~w(GET POST PUT PATCH DELETE)
  @allowed_headers ~w(accept accept-language authorization content-type x-simplefit-csrf)
  @exposed_headers ~w(x-request-id)
  @max_age 600
  # The only paths that read a cookie (the web refresh token, ADR 0010).
  @credentialed_paths [
    "/api/auth/session/refresh",
    "/api/auth/logout",
    # Email authentication can start a session with the cookie transport
    # (ADR 0012).
    "/api/auth/email/registrations/verify",
    "/api/auth/email/sign-in/verify",
    # Google sign-in can start a session with the cookie transport (ADR 0013).
    "/api/auth/google",
    # So can Sign in with Apple (ADR 0014).
    "/api/auth/apple"
  ]

  @origin_format ~r"\Ahttps?://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:\d{1,5})?\z"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Conn{} = conn, _opts) do
    case Conn.get_req_header(conn, "origin") do
      [origin | _] -> handle(conn, origin, preflight?(conn))
      [] -> conn
    end
  end

  defp preflight?(%Conn{method: "OPTIONS"} = conn),
    do: Conn.get_req_header(conn, "access-control-request-method") != []

  defp preflight?(_conn), do: false

  defp handle(conn, origin, true = _preflight) do
    if allowed_origin?(origin) and allowed_preflight?(conn) do
      conn
      |> put_origin_headers(origin)
      |> Conn.put_resp_header("access-control-allow-methods", Enum.join(@allowed_methods, ", "))
      |> Conn.put_resp_header("access-control-allow-headers", Enum.join(@allowed_headers, ", "))
      |> Conn.put_resp_header("access-control-max-age", Integer.to_string(@max_age))
      |> Conn.send_resp(204, "")
      |> Conn.halt()
    else
      conn
      |> vary_origin()
      |> APIError.send_error("forbidden")
    end
  end

  defp handle(conn, origin, false = _preflight) do
    if allowed_origin?(origin) do
      conn
      |> put_origin_headers(origin)
      |> Conn.put_resp_header("access-control-expose-headers", Enum.join(@exposed_headers, ", "))
    else
      vary_origin(conn)
    end
  end

  defp allowed_preflight?(conn) do
    [method | _] = Conn.get_req_header(conn, "access-control-request-method")

    requested_headers =
      conn
      |> Conn.get_req_header("access-control-request-headers")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))

    String.upcase(method) in @allowed_methods and
      Enum.all?(requested_headers, &(&1 in @allowed_headers))
  end

  defp allowed_origin?(origin), do: String.downcase(origin) in allowed_origins()

  defp put_origin_headers(conn, origin) do
    conn
    |> vary_origin()
    |> Conn.put_resp_header("access-control-allow-origin", origin)
    |> allow_credentials()
  end

  defp allow_credentials(%Conn{request_path: path} = conn) when path in @credentialed_paths,
    do: Conn.put_resp_header(conn, "access-control-allow-credentials", "true")

  defp allow_credentials(conn), do: conn

  # The response depends on Origin, so shared caches must key on it.
  defp vary_origin(conn), do: Conn.put_resp_header(conn, "vary", "origin")

  @doc "The configured allow-list (normalised, lower-case origins)."
  @spec allowed_origins() :: [String.t()]
  def allowed_origins do
    Application.get_env(:simple_fit, __MODULE__, [])[:allowed_origins] || []
  end

  @doc """
  Parses `CORS_ALLOWED_ORIGINS` (comma-separated origins) for
  `config/runtime.exs`. Raises with a clear message on anything that is not
  an exact `scheme://host[:port]` origin, so a bad production configuration
  fails at boot instead of silently allowing more than intended.

    * `*`, paths, trailing slashes, query strings and credentials are rejected.
    * `require_https: true` (production) rejects `http://` origins.
    * `nil` or a blank string yields `[]` (no browser origin allowed).
  """
  @spec parse_origins!(String.t() | nil, keyword()) :: [String.t()]
  def parse_origins!(value, opts \\ [])

  def parse_origins!(nil, _opts), do: []

  def parse_origins!(value, opts) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&validate_origin!(&1, opts))
    |> Enum.uniq()
  end

  defp validate_origin!(origin, opts) do
    normalised = String.downcase(origin)

    cond do
      not Regex.match?(@origin_format, normalised) ->
        raise ArgumentError,
              "CORS_ALLOWED_ORIGINS: #{inspect(origin)} is not an exact origin " <>
                "(expected scheme://host[:port], e.g. https://app.example.com; wildcards, " <>
                "paths and trailing slashes are not allowed)"

      opts[:require_https] && String.starts_with?(normalised, "http://") ->
        raise ArgumentError,
              "CORS_ALLOWED_ORIGINS: #{inspect(origin)} must use https in production"

      true ->
        normalised
    end
  end
end
