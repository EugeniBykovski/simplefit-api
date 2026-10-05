defmodule SimpleFitWeb.Schemas.HealthResponse do
  @moduledoc "OpenAPI schema for `GET /api/health`."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "HealthResponse",
      description: "Liveness status of the API process.",
      type: :object,
      required: [:status, :service],
      additionalProperties: false,
      properties: %{
        status: %Schema{
          type: :string,
          enum: ["ok"],
          description: "Always `ok` when the process can serve requests."
        },
        service: %Schema{
          type: :string,
          enum: ["simplefit-api"],
          description: "Service identifier."
        }
      },
      example: %{status: "ok", service: "simplefit-api"}
    },
    struct?: false
  )
end
