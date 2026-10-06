defmodule SimpleFitWeb.Router do
  use SimpleFitWeb, :router

  # Routing layout (see docs/architecture/adr/0003-api-versioning-and-errors.md):
  #
  #   /api/health, /api/openapi, /api/docs   operational, unversioned
  #   /api/me, /api/auth/...                 session and viewer, unversioned (ADR 0010)
  #   /dev/emails                            email template preview, development only (ADR 0011)
  #   /api/v1/...                            product resources (none yet)

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: SimpleFitWeb.ApiSpec
  end

  # Requires a valid SimpleFit access token (Authorization: Bearer sfa_...).
  pipeline :authenticated do
    plug SimpleFitWeb.Plugs.Authenticate
  end

  pipeline :api_docs do
    plug :require_api_docs_enabled
  end

  pipeline :api_docs_page do
    plug :accepts, ["html"]
  end

  scope "/api", SimpleFitWeb do
    pipe_through :api

    get "/health", HealthController, :show

    post "/auth/session/refresh", SessionController, :refresh
    post "/auth/logout", SessionController, :logout
  end

  scope "/api", SimpleFitWeb do
    pipe_through [:api, :authenticated]

    get "/me", MeController, :show
  end

  scope "/api" do
    pipe_through [:api_docs, :api]

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", SimpleFitWeb do
    pipe_through [:api_docs, :api_docs_page]

    get "/docs", ApiDocsController, :show
  end

  # Development-only transactional email preview (ADR 0011).
  pipeline :email_previews do
    plug :require_email_previews_enabled
  end

  scope "/dev/emails", SimpleFitWeb do
    pipe_through :email_previews

    get "/", EmailPreviewController, :index
    get "/:id", EmailPreviewController, :show
  end

  # Docs routes answer exactly like an unknown route when disabled, so a
  # production deployment does not reveal that they exist.
  defp require_api_docs_enabled(conn, _opts) do
    if Application.get_env(:simple_fit, :api_docs, [])[:enabled] do
      conn
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__
    end
  end

  # Enabled only by config/dev.exs (never from the environment), so the
  # previews cannot be switched on in production.
  defp require_email_previews_enabled(conn, _opts) do
    if Application.get_env(:simple_fit, :email_previews, [])[:enabled] do
      conn
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__
    end
  end
end
