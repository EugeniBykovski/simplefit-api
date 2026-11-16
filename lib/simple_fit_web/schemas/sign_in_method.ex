defmodule SimpleFitWeb.Schemas.SignInMethod do
  @moduledoc """
  OpenAPI schemas of the viewer's sign-in methods (SF-161). Examples use
  placeholder values only.
  """

  alias OpenApiSpex.Schema

  @doc false
  def method,
    do: %Schema{
      title: "SignInMethod",
      type: :object,
      description:
        "A way to sign in to the viewer's account. Carries no credential and no provider account id.",
      required: [:provider, :email, :linked_at],
      additionalProperties: false,
      properties: %{
        provider: %Schema{
          type: :string,
          enum: ["email", "google", "apple"],
          description:
            "`email`: a 6-digit code sent to `email`; `google`, `apple`: that provider's sign-in."
        },
        email: %Schema{
          type: :string,
          format: :email,
          nullable: true,
          description:
            "The canonical address of an `email` method; `null` for `google` and `apple` (a provider-reported email is never listed)."
        },
        linked_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the method was added to this account."
        }
      }
    }
end

defmodule SimpleFitWeb.Schemas.SignInMethodList do
  @moduledoc "OpenAPI schema: the viewer's sign-in methods."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SignInMethod

  OpenApiSpex.schema(
    %{
      title: "SignInMethodList",
      description: "The viewer's sign-in methods, oldest first.",
      type: :object,
      required: [:sign_in_methods],
      additionalProperties: false,
      properties: %{
        sign_in_methods: %Schema{type: :array, items: SignInMethod.method()}
      },
      example: %{
        sign_in_methods: [
          %{provider: "email", email: "fighter@example.com", linked_at: "2026-10-01T10:00:00Z"},
          %{provider: "google", email: nil, linked_at: "2026-10-05T18:30:00Z"}
        ]
      }
    },
    struct?: false
  )
end
