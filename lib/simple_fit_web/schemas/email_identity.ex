defmodule SimpleFitWeb.Schemas.EmailIdentity do
  @moduledoc """
  OpenAPI schemas of verified email identity linking (SF-77, ADR 0024).
  Examples use placeholder values only, never real credentials.
  """

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.EmailAuth

  @doc false
  def identity,
    do: %Schema{
      title: "EmailIdentity",
      type: :object,
      description:
        "An email identity of the viewer: an address whose ownership was proven with a code sent to it.",
      required: [:email, :linked_at],
      additionalProperties: false,
      properties: %{
        email: %Schema{
          type: :string,
          format: :email,
          description:
            "The canonical address (ADR 0009: trimmed, lowercased, nothing else rewritten)."
        },
        linked_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the address became an identity of this account."
        }
      }
    }

  @doc false
  def email, do: EmailAuth.email()

  @doc false
  def code, do: EmailAuth.code()

  @doc false
  def accepted_properties, do: EmailAuth.accepted_properties()
end

defmodule SimpleFitWeb.Schemas.EmailIdentityList do
  @moduledoc "OpenAPI schema: the viewer's email identities."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.EmailIdentity

  OpenApiSpex.schema(
    %{
      title: "EmailIdentityList",
      description:
        "The viewer's email identities, oldest first. Google and Apple sign-ins are not listed, and an email a provider reported is never one.",
      type: :object,
      required: [:email_identities],
      additionalProperties: false,
      properties: %{
        email_identities: %Schema{type: :array, items: EmailIdentity.identity()}
      },
      example: %{
        email_identities: [%{email: "fighter@example.com", linked_at: "2026-10-23T09:00:00Z"}]
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailIdentityLinkRequest do
  @moduledoc "OpenAPI schema: ask for a code to link an email address."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailIdentity

  OpenApiSpex.schema(
    %{
      title: "EmailIdentityLinkRequest",
      type: :object,
      required: [:email],
      additionalProperties: false,
      properties: %{email: EmailIdentity.email()},
      example: %{email: "fighter@example.com"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailIdentityLinkAccepted do
  @moduledoc "OpenAPI schema: an email identity link code was requested."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailIdentity

  OpenApiSpex.schema(
    %{
      title: "EmailIdentityLinkAccepted",
      description:
        "Always returned for a well-formed address, whoever owns it: a 6-digit code is on its way to it.",
      type: :object,
      required: [:expires_in_seconds, :resend_after_seconds],
      additionalProperties: false,
      properties: EmailIdentity.accepted_properties(),
      example: %{expires_in_seconds: 600, resend_after_seconds: 60}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailIdentityLinkConfirmRequest do
  @moduledoc "OpenAPI schema: confirm an email identity link with its code."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.EmailIdentity

  OpenApiSpex.schema(
    %{
      title: "EmailIdentityLinkConfirmRequest",
      type: :object,
      required: [:email, :code],
      additionalProperties: false,
      properties: %{email: EmailIdentity.email(), code: EmailIdentity.code()},
      example: %{email: "fighter@example.com", code: "123456"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EmailIdentityLinkResult do
  @moduledoc "OpenAPI schema: a confirmed email identity link."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.EmailIdentity

  OpenApiSpex.schema(
    %{
      title: "EmailIdentityLinkResult",
      description: "The address is an email identity of the viewer.",
      type: :object,
      required: [:outcome, :email_identity],
      additionalProperties: false,
      properties: %{
        outcome: %Schema{
          type: :string,
          enum: ["linked", "already_linked"],
          description:
            "`linked` - added now. `already_linked` - it already was an identity of this account (nothing changed)."
        },
        email_identity: EmailIdentity.identity()
      },
      example: %{
        outcome: "linked",
        email_identity: %{email: "fighter@example.com", linked_at: "2026-10-23T09:00:00Z"}
      }
    },
    struct?: false
  )
end
