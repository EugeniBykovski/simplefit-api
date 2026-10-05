defmodule SimpleFitWeb.Schemas.Error do
  @moduledoc "OpenAPI schema for the error object inside the error envelope."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.APIError
  alias SimpleFitWeb.Schemas.Examples

  OpenApiSpex.schema(
    %{
      title: "Error",
      description: "Machine-readable error. See the ErrorResponse schema for the contract.",
      type: :object,
      required: [:code, :message, :details, :request_id],
      additionalProperties: false,
      properties: %{
        code: %Schema{
          type: :string,
          pattern: "^[a-z][a-z0-9_]*$",
          description: """
          Stable snake_case error code. Clients branch on this value, never on `message`.
          New codes may be added over time; treat unknown codes according to the HTTP status.
          Known codes: #{Enum.map_join(APIError.codes(), ", ", &"`#{&1}`")}.
          """,
          example: "not_found"
        },
        message: %Schema{
          type: :string,
          description:
            "Human-readable English summary. Not localised; may change without notice.",
          example: APIError.message("not_found")
        },
        details: %Schema{
          type: :object,
          additionalProperties: true,
          description: """
          Code-specific structured data; an empty object when there is nothing to add.
          For `validation_error` it is a `ValidationErrorDetails`: `fields` maps each invalid
          field to human-readable messages and `field_codes` to the matching machine-readable
          reason codes (same order).
          """,
          example: %{}
        },
        request_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "Value of the `x-request-id` response header, for support and log correlation.",
          example: Examples.request_id()
        }
      },
      example: APIError.envelope(404, request_id: Examples.request_id()).error
    },
    struct?: false
  )
end
