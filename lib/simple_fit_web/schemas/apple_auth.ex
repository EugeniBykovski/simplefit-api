defmodule SimpleFitWeb.Schemas.AppleAuthRequest do
  @moduledoc "OpenAPI schema: sign in with an Apple identity token (ADR 0014)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "AppleAuthRequest",
      description: """
      `id_token` is the Apple identity token (a JWT) from Sign in with Apple (Apple JS on the web, iOS). Its
      request must have carried the lowercase hex SHA-256 of `nonce`; the raw `nonce` is sent here. Both are
      verified by the API and never stored. Nothing else about the person (name, email) is sent or trusted.
      """,
      type: :object,
      required: [:id_token, :nonce],
      additionalProperties: false,
      properties: %{
        id_token: %Schema{
          type: :string,
          minLength: 1,
          description: "Apple identity token. Sensitive: never log or persist it."
        },
        nonce: %Schema{
          type: :string,
          minLength: 32,
          maxLength: 128,
          pattern: "^[A-Za-z0-9_-]+$",
          description:
            "The raw nonce whose SHA-256 (lowercase hex) was sent to Apple. Sensitive: never log or persist it."
        },
        refresh_token_transport: %Schema{
          type: :string,
          enum: ["body", "cookie"],
          default: "body",
          description: """
          How to deliver the refresh token (ADR 0010). `body` (mobile) returns it in JSON. `cookie` (web) sets
          the `HttpOnly` refresh cookie and requires an allow-listed `Origin` and `x-simplefit-csrf: 1`.
          """
        }
      },
      example: %{
        id_token: "<apple-identity-token>",
        nonce: "example-raw-nonce-base64url-of-32-random-bytes",
        refresh_token_transport: "cookie"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.AppleAuthResponse do
  @moduledoc "OpenAPI schema: the session started by a Sign in with Apple (ADR 0014)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SessionTokens

  @session SessionTokens.schema()

  OpenApiSpex.schema(
    %{
      title: "AppleAuthResponse",
      description: """
      The SimpleFit session (same fields as `SessionTokens`) plus `account`: `created` on the first sign-in of
      this Apple account, `existing` afterwards. A temporary routing signal for first-time onboarding until
      profile/onboarding state is exposed by the API.
      """,
      type: :object,
      required: @session.required ++ [:account],
      additionalProperties: false,
      properties:
        Map.put(@session.properties, :account, %Schema{
          type: :string,
          enum: ["created", "existing"]
        }),
      example: Map.put(@session.example, :account, "created")
    },
    struct?: false
  )
end
