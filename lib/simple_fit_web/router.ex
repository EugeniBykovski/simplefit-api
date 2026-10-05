defmodule SimpleFitWeb.Router do
  use SimpleFitWeb, :router

  # Routing layout (see docs/architecture/adr/0003-api-versioning-and-errors.md):
  #
  #   /api/health, /api/openapi, /api/docs   operational, unversioned
  #   /api/v1/...                            product resources (none yet)

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: SimpleFitWeb.ApiSpec
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
  end

  scope "/api" do
    pipe_through [:api_docs, :api]

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", SimpleFitWeb do
    pipe_through [:api_docs, :api_docs_page]

    get "/docs", ApiDocsController, :show
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
end
