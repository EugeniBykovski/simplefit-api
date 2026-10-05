defmodule SimpleFitWeb.HealthController do
  @moduledoc """
  Liveness endpoint for load balancers, uptime checks and clients.

  Deliberately does not touch the database or report versions, hosts or
  configuration: it answers "can this process serve HTTP?" and nothing else.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SimpleFitWeb.{ApiSpec, Schemas}

  tags ["System"]

  operation :show,
    operation_id: "getHealth",
    summary: "Liveness check",
    description: "Returns `200 ok` while the API process is able to serve requests.",
    responses: [
      ok: {"Service is alive", "application/json", Schemas.HealthResponse},
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, _params) do
    render(conn, :show)
  end
end
