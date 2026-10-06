defmodule SimpleFitWeb.Schemas.CurrentUserResponse do
  @moduledoc "OpenAPI schema for `GET /api/me`."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CurrentUserResponse",
      description: """
      The authenticated viewer. `user` is the one global SimpleFit user; capabilities such as profiles
      and workspace memberships will be added as sibling fields when they exist.
      """,
      type: :object,
      required: [:user],
      additionalProperties: false,
      properties: %{
        user: %Schema{
          type: :object,
          required: [:id, :created_at],
          additionalProperties: false,
          properties: %{
            id: %Schema{type: :string, format: :uuid, description: "Stable user id."},
            created_at: %Schema{type: :string, format: :"date-time"}
          }
        }
      },
      example: %{
        user: %{id: "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5", created_at: "2026-10-06T12:00:00Z"}
      }
    },
    struct?: false
  )
end
