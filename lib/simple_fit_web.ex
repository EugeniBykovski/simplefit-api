defmodule SimpleFitWeb do
  @moduledoc """
  The entrypoint for defining the HTTP interface: the router and
  controllers.

  This can be used in your application as:

      use SimpleFitWeb, :controller
      use SimpleFitWeb, :router

  The web layer translates HTTP into calls to domain contexts (`SimpleFit.*`)
  and renders their results as JSON. It owns no business rules. See
  docs/architecture/README.md for conventions.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: SimpleFitWeb.Endpoint,
        router: SimpleFitWeb.Router
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/router/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
