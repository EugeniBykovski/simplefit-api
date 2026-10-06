defmodule SimpleFitWeb.Schemas.GoogleAuthRequest do
  @moduledoc "OpenAPI schema: sign in with a Google ID token (ADR 0013)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GoogleAuthRequest",
      description: """
      `id_token` is the Google ID token (a JWT) from Google Identity Services (web) or Google Sign-In (iOS,
      Android). It is verified by the API and never stored. Nothing else about the person is sent or trusted.
      """,
      type: :object,
      required: [:id_token],
      additionalProperties: false,
      properties: %{
        id_token: %Schema{
          type: :string,
          minLength: 1,
          description: "Google ID token. Sensitive: never log or persist it."
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
      example: %{id_token: "<google-id-token>", refresh_token_transport: "cookie"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GoogleAuthResponse do
  @moduledoc "OpenAPI schema: the session started by a Google sign-in (ADR 0013)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SessionTokens

  @session SessionTokens.schema()

  OpenApiSpex.schema(
    %{
      title: "GoogleAuthResponse",
      description: """
      The SimpleFit session (same fields as `SessionTokens`) plus `account`: `created` on the first Google
      sign-in of this Google account, `existing` afterwards. A temporary routing signal for first-time
      onboarding until profile/onboarding state is exposed by the API.
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
