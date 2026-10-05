defmodule SimpleFitWeb.Schemas.ErrorResponse do
  @moduledoc "OpenAPI schema for the error envelope returned by every non-2xx response."

  require OpenApiSpex

  alias SimpleFitWeb.APIError
  alias SimpleFitWeb.Schemas.Examples

  OpenApiSpex.schema(
    %{
      title: "ErrorResponse",
      description: """
      Envelope returned with every 4xx and 5xx response. Stack traces and internal details
      are never included.
      """,
      type: :object,
      required: [:error],
      additionalProperties: false,
      properties: %{
        error: SimpleFitWeb.Schemas.Error
      },
      example: APIError.envelope(404, request_id: Examples.request_id())
    },
    struct?: false
  )
end
