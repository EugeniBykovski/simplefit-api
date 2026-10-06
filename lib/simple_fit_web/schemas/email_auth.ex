defmodule SimpleFitWeb.Schemas.EmailAuth do
  @moduledoc """
  OpenAPI schemas of passwordless email authentication (ADR 0012). Examples
  use placeholder values only, never real credentials.
  """

  alias OpenApiSpex.Schema

  @registration_token_example "sfg_EXAMPLExREGISTRATIONxTOKENxNOTxAxREALxVALUE"
  @link_token_example "sfv_EXAMPLExLINKxTOKENxNOTxAxREALxVALUExxxxxxxx"

  @doc false
  def email,
    do: %Schema{
      type: :string,
      format: :email,
      maxLength: 254,
      description: "Email address; matched in canonical form (ADR 0009).",
      example: "fighter@example.com"
    }

  @doc false
  def code,
    do: %Schema{
      type: :string,
      pattern: "^[0-9]{6}$",
      description: "The 6-digit code from the email.",
      example: "123456"
    }

  @doc false
  def registration_token,
    do: %Schema{
      type: :string,
      pattern: "^sfg_[A-Za-z0-9_-]{43}$",
      description:
        "Opaque token of this registration, held only by the client that started it. Never sent by email.",
      example: @registration_token_example
    }

  @doc false
  def transport,
    do: %Schema{
      type: :string,
      enum: ["body", "cookie"],
      default: "body",
      description: """
      How to deliver the refresh token (ADR 0010). `body` (mobile) returns it in JSON. `cookie` (web) sets
      the `HttpOnly` refresh cookie and requires an allow-listed `Origin` and `x-simplefit-csrf: 1`.
      """
    }

  @doc false
  def accepted_properties,
    do: %{
      expires_in_seconds: %Schema{
        type: :integer,
        description: "Lifetime of the code (and link).",
        example: 600
      },
      resend_after_seconds: %Schema{
        type: :integer,
        description: "Wait at least this long before requesting another code.",
        example: 60
      }
    }

  @doc false
  def link_token_example, do: @link_token_example

  @doc false
  def registration_token_example, do: @registration_token_example
end

defmodule SimpleFitWeb.Schemas.EmailCodeRequest do
  @moduledoc "OpenAPI schema: request an email code for an address."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailAuth

  OpenApiSpex.schema(
    %{
      title: "EmailCodeRequest",
      type: :object,
      required: [:email],
      additionalProperties: false,
      properties: %{email: EmailAuth.email()},
      example: %{email: "fighter@example.com"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailRegistrationAccepted do
  @moduledoc "OpenAPI schema: a registration's verification email was requested."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailAuth

  OpenApiSpex.schema(
    %{
      title: "EmailRegistrationAccepted",
      description: """
      Always returned for a well-formed address, whether or not it already has an account. Keep
      `registration_token` for this registration only (memory or secure storage); a new request replaces it.
      """,
      type: :object,
      required: [:registration_token, :expires_in_seconds, :resend_after_seconds],
      additionalProperties: false,
      properties:
        Map.put(
          EmailAuth.accepted_properties(),
          :registration_token,
          EmailAuth.registration_token()
        ),
      example: %{
        registration_token: EmailAuth.registration_token_example(),
        expires_in_seconds: 600,
        resend_after_seconds: 60
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailSignInAccepted do
  @moduledoc "OpenAPI schema: an email sign-in code was requested."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailAuth

  OpenApiSpex.schema(
    %{
      title: "EmailSignInAccepted",
      description:
        "Always returned for a well-formed address. If there is an account for it, a 6-digit sign-in code (E17) is on its way.",
      type: :object,
      required: [:expires_in_seconds, :resend_after_seconds],
      additionalProperties: false,
      properties: EmailAuth.accepted_properties(),
      example: %{expires_in_seconds: 600, resend_after_seconds: 60}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailRegistrationCodeRequest do
  @moduledoc "OpenAPI schema: verify a registration with its code."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailAuth

  OpenApiSpex.schema(
    %{
      title: "EmailRegistrationCodeRequest",
      type: :object,
      required: [:registration_token, :code],
      additionalProperties: false,
      properties: %{
        registration_token: EmailAuth.registration_token(),
        code: EmailAuth.code(),
        refresh_token_transport: EmailAuth.transport()
      },
      example: %{
        registration_token: EmailAuth.registration_token_example(),
        code: "123456",
        refresh_token_transport: "body"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailRegistrationStatusRequest do
  @moduledoc "OpenAPI schema: the state of a registration."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailAuth

  OpenApiSpex.schema(
    %{
      title: "EmailRegistrationStatusRequest",
      type: :object,
      required: [:registration_token],
      additionalProperties: false,
      properties: %{registration_token: EmailAuth.registration_token()},
      example: %{registration_token: EmailAuth.registration_token_example()}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailRegistrationStatus do
  @moduledoc "OpenAPI schema: the state of a registration."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "EmailRegistrationStatus",
      description: """
      * `pending` - waiting for the code.
      * `completed` - verified with this client's code; its session was issued.
      * `verified_elsewhere` - verified through the E01 link on another device. This client is not signed in:
        request an email sign-in code (`POST /api/auth/email/sign-in`) to continue.
      * `expired` - expired, replaced by a newer request, too many wrong codes, or unknown.
      """,
      type: :object,
      required: [:status],
      additionalProperties: false,
      properties: %{
        status: %Schema{
          type: :string,
          enum: ["pending", "completed", "verified_elsewhere", "expired"]
        }
      },
      example: %{status: "pending"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailVerificationLinkRequest do
  @moduledoc "OpenAPI schema: verify an email with the E01 link token."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.EmailAuth

  OpenApiSpex.schema(
    %{
      title: "EmailVerificationLinkRequest",
      description:
        "The token from the fragment of the E01 link (`/verify-email#token=...`), sent in the body. The fragment never reaches a server by itself.",
      type: :object,
      required: [:token],
      additionalProperties: false,
      properties: %{
        token: %Schema{
          type: :string,
          pattern: "^sfv_[A-Za-z0-9_-]{43}$",
          example: EmailAuth.link_token_example()
        }
      },
      example: %{token: EmailAuth.link_token_example()}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailVerificationLinkResult do
  @moduledoc "OpenAPI schema: result of an E01 link."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "EmailVerificationLinkResult",
      description:
        "`verified`: the email is now verified. `already_verified`: nothing more to do. No one is signed in either way.",
      type: :object,
      required: [:status],
      additionalProperties: false,
      properties: %{status: %Schema{type: :string, enum: ["verified", "already_verified"]}},
      example: %{status: "verified"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailSignInCodeRequest do
  @moduledoc "OpenAPI schema: sign in with an email sign-in code."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailAuth

  OpenApiSpex.schema(
    %{
      title: "EmailSignInCodeRequest",
      type: :object,
      required: [:email, :code],
      additionalProperties: false,
      properties: %{
        email: EmailAuth.email(),
        code: EmailAuth.code(),
        refresh_token_transport: EmailAuth.transport()
      },
      example: %{email: "fighter@example.com", code: "123456", refresh_token_transport: "body"}
    },
    struct?: false
  )
end
