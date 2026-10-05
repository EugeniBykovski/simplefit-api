defmodule SimpleFitWeb.ApiDocsController do
  @moduledoc """
  Interactive API reference (Scalar) rendered from `/api/openapi`.

  The page is a static shell around the pinned Scalar bundle; there is no
  custom documentation frontend. It is only routed when API docs are enabled
  (on in dev/test, opt-in via API_DOCS_ENABLED in production).

  The bundle is version-pinned and loaded with Subresource Integrity, and the
  page gets its own Content-Security-Policy: scripts only from the pinned CDN
  file and the inline bootstrap (by hash), network access only to this
  origin. Scalar telemetry, its AI agent and remote fonts are disabled.

  To upgrade Scalar, change `@scalar_version` and `@scalar_integrity`
  (sha384 of the new `dist/browser/standalone.js`, base64-encoded).
  """

  use SimpleFitWeb, :controller

  @scalar_version "1.72.4"
  @scalar_integrity "sha384-omTRdD9MbjA1vm12DqRUVvqJlr3VzSixvAdF1Jruu9AJOiJKyTKraIB6DyX+m10M"
  @scalar_src "https://cdn.jsdelivr.net/npm/@scalar/api-reference@#{@scalar_version}/dist/browser/standalone.js"

  @scalar_config %{
    url: "/api/openapi",
    telemetry: false,
    withDefaultFonts: false,
    agent: %{disabled: true},
    mcp: %{disabled: true},
    showDeveloperTools: "never",
    persistAuth: false,
    documentDownloadType: "json"
  }

  @bootstrap_script "Scalar.createApiReference('#app', #{Jason.encode!(@scalar_config)})"
  @bootstrap_hash :sha256 |> :crypto.hash(@bootstrap_script) |> Base.encode64()

  @content_security_policy Enum.join(
                             [
                               "default-src 'none'",
                               "script-src #{@scalar_src} 'sha256-#{@bootstrap_hash}'",
                               "style-src 'self' 'unsafe-inline'",
                               "img-src 'self' data:",
                               "font-src 'self' data:",
                               "connect-src 'self'",
                               "worker-src 'self' blob:",
                               "frame-ancestors 'none'",
                               "base-uri 'none'",
                               "form-action 'none'"
                             ],
                             "; "
                           )

  @page """
  <!doctype html>
  <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="robots" content="noindex, nofollow">
      <title>SimpleFit API Reference</title>
    </head>
    <body>
      <div id="app"></div>
      <script src="#{@scalar_src}" integrity="#{@scalar_integrity}" crossorigin="anonymous"></script>
      <script>#{@bootstrap_script}</script>
    </body>
  </html>
  """

  def show(conn, _params) do
    conn
    |> put_resp_header("content-security-policy", @content_security_policy)
    |> put_resp_header("cache-control", "no-store")
    |> html(@page)
  end
end
