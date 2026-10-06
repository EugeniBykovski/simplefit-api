defmodule SimpleFitWeb.Schemas.RefreshSessionRequest do
  @moduledoc "OpenAPI schema for the body-transport refresh token (`POST /api/auth/session/refresh`, `POST /api/auth/logout`)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "RefreshSessionRequest",
      description:
        "Body transport (mobile and other non-browser clients). Web clients send the refresh cookie instead and no body token.",
      type: :object,
      required: [:refresh_token],
      additionalProperties: false,
      properties: %{
        refresh_token: %Schema{
          type: :string,
          pattern: "^sfr_[A-Za-z0-9_-]{43}$",
          description: "The refresh token from the last session response. Single use."
        }
      },
      example: %{refresh_token: "sfr_3q2-7wQYz1bYH0Cq5Zf8d9E0aB1cD2eF3gH4iJ5kL6m"}
    },
    struct?: false
  )
end
