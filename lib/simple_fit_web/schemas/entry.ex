defmodule SimpleFitWeb.Schemas.EntryResponse do
  @moduledoc "OpenAPI schema: post-authentication entry resolution (ADR 0017)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Entry

  @destinations Enum.map(Entry.destinations(), &Atom.to_string/1)
  @reasons Enum.map(Entry.reasons(), &Atom.to_string/1)
  @intents Enum.map(Entry.intents(), &Atom.to_string/1)
  @contexts Enum.map(Entry.contexts(), &Atom.to_string/1)
  @profile_statuses ["not_started", "in_progress", "completed"]

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
            :context,
            :account_registration,
            :fighter_profile,
            :coach_profile,
            :capabilities
          ],
          additionalProperties: false,
          properties: %{
            destination: %Schema{
              type: :string,
              enum: @destinations,
              description: """
              `account_registration`: shared basics and consents (mandatory). `role_selection`: the user chooses
              a journey to start. `context_selection`: the user chooses between their profile contexts (both
              completed without a remembered choice, or both onboardings in progress). `fighter_onboarding` /
              `fighter_home` and `coach_onboarding` / `coach_home`: a profile's onboarding, or its application
              once completed. `gym_onboarding`, `sponsor_application`: those journeys' entry points; nothing is
              created for them. A client that does not know a destination must fail visibly, never guess.
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
              registration, Fighter or Coach onboarding); the `returnTo` is kept and resolved again afterwards.
              """
            },
            intent: %Schema{
              type: :string,
              enum: @intents,
              nullable: true,
              description: "The validated intent of this request, echoed; never stored."
            },
            context: %Schema{
              type: :string,
              # `null` is listed so strict validators accept a nullable enum.
              enum: @contexts ++ [nil],
              nullable: true,
              description: """
              The requested `context` when it was applied (a completed profile, no `intent`, registration
              complete); otherwise `null`. Never stored.
              """
            },
            account_registration: %Schema{
              type: :string,
              enum: ["not_started", "in_progress", "complete"],
              description: "Shared account registration status (see `getMyAccountProfile`)."
            },
            fighter_profile: %Schema{
              type: :string,
              enum: @profile_statuses,
              description: "Fighter onboarding status (see `getMyFighterProfile`)."
            },
            coach_profile: %Schema{
              type: :string,
              enum: @profile_statuses,
              description: "Coach onboarding status (see `getMyCoachProfile`)."
            },
            capabilities: %Schema{
              type: :array,
              items: %Schema{type: :string, enum: ["FIGHTER", "COACH"]},
              description: """
              Capabilities derived from real backend state, in the client route registry's vocabulary
              (`FIGHTER` once Fighter onboarding is complete, `COACH` once Coach onboarding is complete; both can
              be held at once). A routing projection, not an authorization grant: `COACH` opens the user's own
              Coach application only.
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
          context: nil,
          account_registration: "complete",
          fighter_profile: "in_progress",
          coach_profile: "completed",
          capabilities: ["COACH"]
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EntryContextChoiceRequest do
  @moduledoc "OpenAPI schema: an explicit choice of application context (SF-51)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Entry

  OpenApiSpex.schema(
    %{
      title: "EntryContextChoiceRequest",
      description: "The profile context the viewer chose. Must be a completed profile.",
      type: :object,
      required: [:context],
      additionalProperties: false,
      properties: %{
        context: %Schema{
          type: :string,
          enum: Enum.map(Entry.contexts(), &Atom.to_string/1),
          description:
            "`fighter` or `coach`. Profile contexts only; gym workspaces are chosen elsewhere."
        }
      },
      example: %{context: "coach"}
    },
    struct?: false
  )
end
