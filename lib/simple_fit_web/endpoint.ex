defmodule SimpleFitWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :simple_fit

  alias Plug.Conn.WrapperError

  # SimpleFit is a JSON API consumed by web and mobile clients. It serves no
  # static files, keeps no cookie session and accepts only JSON request
  # bodies. Authentication will use bearer tokens (see
  # docs/architecture/README.md, "Security baseline").

  # Hardened response headers for an API that is never meant to be rendered
  # or framed by a browser. The one HTML page (the API docs, see
  # SimpleFitWeb.ApiDocsController) sets its own content-security-policy.
  @security_headers [
    {"content-security-policy", "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"},
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"referrer-policy", "no-referrer"},
    {"x-permitted-cross-domain-policies", "none"}
  ]

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :simple_fit
  end

  plug Plug.RequestId
  plug :put_security_headers
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Cross-origin policy (explicit allow-list, answers preflights). After the
  # request id and security headers so preflight responses carry them too.
  plug SimpleFitWeb.CORS

  # Only JSON bodies are accepted. Any other content type is rejected with
  # 415 unsupported_media_type before reaching the router.
  @parsers Plug.Parsers.init(
             parsers: [:json],
             pass: [],
             json_decoder: Phoenix.json_library()
           )

  plug :parse_body
  plug Plug.Head
  plug SimpleFitWeb.Router

  defp put_security_headers(conn, _opts) do
    Plug.Conn.merge_resp_headers(conn, @security_headers)
  end

  # Parser errors (malformed JSON, unsupported media type, oversized body)
  # are re-raised wrapped with the current conn, so the rendered error keeps
  # the x-request-id and security headers set above. Without this, Phoenix
  # renders them from the conn as it entered the endpoint.
  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, @parsers)
  rescue
    exception -> WrapperError.reraise(conn, :error, exception, __STACKTRACE__)
  end
end
