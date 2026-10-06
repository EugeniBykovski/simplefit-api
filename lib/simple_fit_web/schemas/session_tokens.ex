defmodule SimpleFitWeb.Schemas.SessionTokens do
  @moduledoc "OpenAPI schema for issued session credentials (`SimpleFitWeb.SessionJSON`)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SessionTokens",
      description: """
      Credentials of a SimpleFit session. Send `access_token` as `Authorization: Bearer <token>` until
      `access_token_expires_at`, then refresh. `refresh_token` is present only for the body transport;
      with the cookie transport it is in the `Set-Cookie` header and never readable by scripts.
      """,
      type: :object,
      required: [
        :token_type,
        :access_token,
        :access_token_expires_at,
        :refresh_token_expires_at,
        :refresh_token_transport
      ],
      additionalProperties: false,
      properties: %{
        token_type: %Schema{type: :string, enum: ["Bearer"]},
        access_token: %Schema{
          type: :string,
          pattern: "^sfa_",
          description: "Short-lived SimpleFit access token (opaque to clients)."
        },
        access_token_expires_at: %Schema{type: :string, format: :"date-time"},
        refresh_token: %Schema{
          type: :string,
          pattern: "^sfr_[A-Za-z0-9_-]{43}$",
          description: "Body transport only. Keep it in platform secure storage."
        },
        refresh_token_expires_at: %Schema{type: :string, format: :"date-time"},
        refresh_token_transport: %Schema{
          type: :string,
          enum: ["body", "cookie"],
          description: "Where the refresh token was delivered."
        }
      },
      example: %{
        token_type: "Bearer",
        access_token: "sfa_SFMyNTY.g2gDbQAAACQ.LZ3e0J2s5A",
        access_token_expires_at: "2026-10-06T12:15:00Z",
        refresh_token: "sfr_3q2-7wQYz1bYH0Cq5Zf8d9E0aB1cD2eF3gH4iJ5kL6m",
        refresh_token_expires_at: "2026-11-05T12:00:00Z",
        refresh_token_transport: "body"
      }
    },
    struct?: false
  )
end
