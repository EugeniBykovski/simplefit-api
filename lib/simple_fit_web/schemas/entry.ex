defmodule SimpleFitWeb.Schemas.EntryResponse do
  @moduledoc "OpenAPI schema: post-authentication entry resolution (ADR 0017)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Entry

  @destinations Enum.map(Entry.destinations(), &Atom.to_string/1)
  @reasons Enum.map(Entry.reasons(), &Atom.to_string/1)
  @intents Enum.map(Entry.intents(), &Atom.to_string/1)

  OpenApiSpex.schema(
    %{
      title: "EntryResponse",
      description: """
      Where the authenticated user goes next. `destination` is semantic: each client maps it to its own route.
      """,
      type: :object,
      required: [:entry],
      additionalProperties: false,
      properties: %{
        entry: %Schema{
          type: :object,
          required: [
            :destination,
            :reason,
            :mandatory,
            :intent,
            :account_registration,
            :fighter_profile,
            :capabilities
          ],
          additionalProperties: false,
          properties: %{
            destination: %Schema{
              type: :string,
              enum: @destinations,
              description: """
              `account_registration`: shared basics and consents (mandatory). `role_selection`: the user chooses
              where to start. `fighter_onboarding` / `fighter_home`: Fighter onboarding, or the Fighter home once
              complete. `coach_onboarding`, `gym_onboarding`, `sponsor_application`: those journeys' entry points;
              nothing is created for them.
              """
            },
            reason: %Schema{
              type: :string,
              enum: @reasons,
              description:
                "Why this destination was chosen. For diagnostics and copy, not branching."
            },
            mandatory: %Schema{
              type: :boolean,
              description: """
              `true` when the client must go to `destination` even with a safe `returnTo` in hand (account
              registration, unfinished Fighter onboarding); the `returnTo` is kept and resolved again afterwards.
              """
            },
            intent: %Schema{
              type: :string,
              enum: @intents,
              nullable: true,
              description: "The validated intent of this request, echoed; never stored."
            },
            account_registration: %Schema{
              type: :string,
              enum: ["not_started", "in_progress", "complete"],
              description: "Shared account registration status (see `getMyAccountProfile`)."
            },
            fighter_profile: %Schema{
              type: :string,
              enum: ["not_started", "in_progress", "completed"],
              description: "Fighter onboarding status (see `getMyFighterProfile`)."
            },
            capabilities: %Schema{
              type: :array,
              items: %Schema{type: :string, enum: ["FIGHTER"]},
              description: """
              Capabilities derived from real backend state, in the client route registry's vocabulary
              (`FIGHTER` once Fighter onboarding is complete). A routing projection, not an authorization grant.
              """
            }
          }
        }
      },
      example: %{
        entry: %{
          destination: "fighter_onboarding",
          reason: "fighter_onboarding_in_progress",
          mandatory: true,
          intent: "fighter",
          account_registration: "complete",
          fighter_profile: "in_progress",
          capabilities: []
        }
      }
    },
    struct?: false
  )
end
