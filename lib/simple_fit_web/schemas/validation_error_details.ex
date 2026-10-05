defmodule SimpleFitWeb.Schemas.ValidationErrorDetails do
  @moduledoc "OpenAPI schema for `details` of a `validation_error` (see `SimpleFitWeb.ChangesetErrors`)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.ChangesetErrors

  @messages %Schema{type: :array, items: %Schema{type: :string}}
  @codes %Schema{
    type: :array,
    items: %Schema{type: :string, enum: ChangesetErrors.reason_codes()}
  }

  OpenApiSpex.schema(
    %{
      title: "ValidationErrorDetails",
      description: """
      `details` of a `validation_error`. Both maps have the same keys (field names; nested
      fields use dotted paths such as `address.city`) and, per field, the same number of entries
      in the same order: `field_codes[field][i]` is the reason for `fields[field][i]`.
      Clients branch on `field_codes`, never on the messages in `fields`. New reason codes may
      be added; treat unknown ones as `invalid`.
      """,
      type: :object,
      required: [:fields, :field_codes],
      properties: %{
        fields: %Schema{
          type: :object,
          additionalProperties: @messages,
          description:
            "Field name to human-readable messages (English, for display and debugging)."
        },
        field_codes: %Schema{
          type: :object,
          additionalProperties: @codes,
          description: "Field name to stable machine-readable reason codes."
        }
      },
      example: %{
        fields: %{
          "email" => ["can't be blank", "has invalid format"],
          "date_of_birth" => ["is invalid"]
        },
        field_codes: %{
          "email" => ["required", "invalid_format"],
          "date_of_birth" => ["invalid_type"]
        }
      }
    },
    struct?: false
  )
end
