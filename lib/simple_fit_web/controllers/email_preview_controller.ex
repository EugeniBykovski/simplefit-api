defmodule SimpleFitWeb.EmailPreviewController do
  @moduledoc """
  Development-only preview of the transactional email templates (ADR 0011).

  `GET /dev/emails` lists every designed email with its status and artboard;
  `GET /dev/emails/:id` renders an implemented template (E01, E11, ...) with
  the deterministic fixtures, as HTML or, with `?format=text`, plain text.

  Routed only when `config :simple_fit, :email_previews, enabled: true`,
  which only `config/dev.exs` sets; otherwise the routes answer exactly like
  unknown routes. Not part of the OpenAPI contract. Nothing is sent.
  """

  use SimpleFitWeb, :controller

  alias SimpleFit.Email.Templates
  alias SimpleFit.Email.Templates.{Fixtures, Inventory}

  # The rendered email uses inline styles; nothing may load or run scripts.
  @content_security_policy "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'"

  def index(conn, _params) do
    rows =
      Enum.map(Inventory.entries(), fn entry ->
        link =
          if entry[:template],
            do: [
              ~s(<a href="/dev/emails/#{entry.id}">HTML</a> · ),
              ~s(<a href="/dev/emails/#{entry.id}?format=text">text</a>)
            ],
            else: "—"

        [
          "<tr><td>",
          entry.id,
          "</td><td>",
          escape(entry.name),
          "</td><td>",
          escape(entry.status),
          "</td><td>",
          escape(entry.artboard),
          "</td><td>",
          link,
          "</td></tr>"
        ]
      end)

    source = Inventory.source()

    send_html(conn, [
      "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Email templates</title></head>",
      ~s(<body style="font-family: system-ui, sans-serif; margin: 24px;">),
      "<h1>Transactional email templates</h1>",
      "<p>Claude Design version ",
      escape(source.version),
      " · ",
      escape(source.section),
      ". Fixture data only; nothing is sent.</p>",
      ~s(<table cellpadding="6" style="border-collapse: collapse;">),
      "<tr><th>Id</th><th>Name</th><th>Status</th><th>Artboard</th><th>Preview</th></tr>",
      rows,
      "</table></body></html>"
    ])
  end

  def show(conn, %{"id" => id} = params) do
    with %{template: template} <- Enum.find(Inventory.entries(), &(&1.id == id)),
         {:ok, rendered} <- apply(Templates, template, [Fixtures.for_template(template)]) do
      if params["format"] == "text",
        do: conn |> put_resp_content_type("text/plain") |> send_resp(200, rendered.text),
        else: send_html(conn, rendered.html)
    else
      _unknown -> raise Phoenix.Router.NoRouteError, conn: conn, router: SimpleFitWeb.Router
    end
  end

  defp send_html(conn, body) do
    conn
    |> put_resp_header("content-security-policy", @content_security_policy)
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end

  defp escape(text), do: Plug.HTML.html_escape(text)
end
