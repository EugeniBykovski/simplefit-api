defmodule SimpleFitWeb.Schemas.PasswordAuth do
  @moduledoc "Shared OpenAPI pieces of the optional password credential (SF-157)."

  alias OpenApiSpex.Schema
  alias SimpleFit.Accounts.Passwords

  @doc "A password: 12 to 128 characters, no composition rules."
  @spec password(String.t()) :: Schema.t()
  def password(description) do
    range = Passwords.length_range()

    %Schema{
      type: :string,
      format: :password,
      minLength: range.first,
      maxLength: range.last,
      writeOnly: true,
      description: description
    }
  end

  @doc "A password as typed at sign-in: never validated beyond presence, so nothing leaks."
  @spec entered_password(String.t()) :: Schema.t()
  def entered_password(description),
    do: %Schema{
      type: :string,
      format: :password,
      minLength: 1,
      writeOnly: true,
      description: description
    }
end

defmodule SimpleFitWeb.Schemas.PasswordSignInRequest do
  @moduledoc "OpenAPI schema: sign in with an email address and password."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.{EmailAuth, PasswordAuth}

  OpenApiSpex.schema(
    %{
      title: "PasswordSignInRequest",
      type: :object,
      required: [:email, :password],
      additionalProperties: false,
      properties: %{
        email: EmailAuth.email(),
        password: PasswordAuth.entered_password("The account's password."),
        refresh_token_transport: EmailAuth.transport()
      },
      example: %{
        email: "founder@example.com",
        password: "correct horse battery staple",
        refresh_token_transport: "cookie"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.PasswordResetAccepted do
  @moduledoc "OpenAPI schema: a password code was requested."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailAuth

  OpenApiSpex.schema(
    %{
      title: "PasswordResetAccepted",
      description:
        "Always returned for a well-formed address. If it is an account's email address, a 6-digit password code is on its way.",
      type: :object,
      required: [:expires_in_seconds, :resend_after_seconds],
      additionalProperties: false,
      properties: EmailAuth.accepted_properties(),
      example: %{expires_in_seconds: 600, resend_after_seconds: 60}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.PasswordResetConfirmRequest do
  @moduledoc "OpenAPI schema: set or reset a password with an emailed code."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.{EmailAuth, PasswordAuth}

  OpenApiSpex.schema(
    %{
      title: "PasswordResetConfirmRequest",
      type: :object,
      required: [:email, :code, :password],
      additionalProperties: false,
      properties: %{
        email: EmailAuth.email(),
        code: EmailAuth.code(),
        password:
          PasswordAuth.password(
            "The new password. Not the account's email address. Replaces any previous password."
          )
      },
      example: %{
        email: "founder@example.com",
        code: "604218",
        password: "correct horse battery staple"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.PasswordChangeRequest do
  @moduledoc "OpenAPI schema: change the viewer's password."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.PasswordAuth

  OpenApiSpex.schema(
    %{
      title: "PasswordChangeRequest",
      type: :object,
      required: [:current_password, :password],
      additionalProperties: false,
      properties: %{
        current_password: PasswordAuth.entered_password("The current password."),
        password:
          PasswordAuth.password("The new password. Not one of the account's email addresses.")
      },
      example: %{
        current_password: "correct horse battery staple",
        password: "a different long passphrase"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.PasswordStatus do
  @moduledoc "OpenAPI schema: whether the viewer has a password."

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "PasswordStatus",
      type: :object,
      required: [:password_set],
      additionalProperties: false,
      properties: %{
        password_set: %OpenApiSpex.Schema{
          type: :boolean,
          description:
            "Whether the viewer can sign in with a password. Never the password or anything derived from it."
        }
      },
      example: %{password_set: true}
    },
    struct?: false
  )
end
