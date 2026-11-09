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
            :gym_id,
            :account_registration,
            :fighter_profile,
            :coach_profile,
            :capabilities,
            :gym_workspaces,
            :gym_workspace_count,
            :sponsor_id,
            :sponsor_workspaces,
            :sponsor_workspace_count
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
              once completed. `gym_onboarding`: start Gym setup (`gym_id` null; nothing is created) or resume the
              draft gym the user owns (`gym_id`). `gym_home`: the gym workspace `gym_id` (a completed gym where the
              user is active staff). `gym_selection`: the user chooses among their gym workspaces
              (`gym_workspaces`). `sponsor_application`: begin a sponsor application; nothing is created.
              `sponsor_application_draft`: resume the viewer's draft application. `sponsor_application_status`: the
              viewer's application status (submitted, under review, changes requested, or a closed one; read it
              with `getMySponsorApplication`). An application grants nothing. `sponsor_home`: the sponsor workspace `sponsor_id` (an active
              organization where the user is an active member; SF-112). `context_selection` also answers a
              `sponsor` intent with several sponsor workspaces and no valid remembered one. A client that does not
              know a destination must fail visibly, never guess.
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
              The requested `context` when it was applied (a completed profile, `gym` with the `gym_id` of a
              completed gym where the user is active staff, or `sponsor` with the `sponsor_id` of an active
              organization where the user is an active member; no `intent`; registration complete); otherwise `null`.
              Never stored.
              """
            },
            gym_id: %Schema{
              type: :string,
              format: :uuid,
              nullable: true,
              description: """
              The gym `destination` refers to (`gym_home`, or `gym_onboarding` resuming a draft); otherwise `null`.
              Navigation only: every gym operation authorizes the gym id in its own path (`/api/v1/gyms/{gym_id}`).
              """
            },
            gym_workspaces: %Schema{
              type: :array,
              maxItems: 25,
              items: SimpleFitWeb.Schemas.EntryGymWorkspace,
              description: """
              The viewer's gym workspaces (active staff memberships), at most 25: the draft the viewer owns first,
              then newest membership first. `gym_workspace_count` is the total; read the rest with `listMyGyms`.
              Re-read on every resolution, so a revoked membership is gone from the next answer.
              """
            },
            gym_workspace_count: %Schema{
              type: :integer,
              minimum: 0,
              description:
                "How many active gym staff memberships the viewer holds (drafts included)."
            },
            sponsor_id: %Schema{
              type: :string,
              format: :uuid,
              nullable: true,
              description: """
              The sponsor organization `destination` refers to (`sponsor_home`); otherwise `null`. Navigation only:
              every sponsor operation authorizes the id in its own path (`/api/v1/sponsor-organizations/{sponsor_id}`).
              """
            },
            sponsor_workspaces: %Schema{
              type: :array,
              maxItems: 25,
              items: SimpleFitWeb.Schemas.EntrySponsorWorkspace,
              description: """
              The viewer's sponsor workspaces (active memberships of active organizations), at most 25, oldest
              membership first. `sponsor_workspace_count` is the total; read them all with
              `listMySponsorOrganizations`. Re-read on every resolution: a revoked or suspended membership is gone
              from the next answer.
              """
            },
            sponsor_workspace_count: %Schema{
              type: :integer,
              minimum: 0,
              description:
                "How many active memberships of active sponsor organizations the viewer holds."
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
              items: %Schema{
                type: :string,
                enum: ["FIGHTER", "COACH", "GYM_WORKSPACE", "SPONSOR_WORKSPACE"]
              },
              description: """
              Capabilities derived from real backend state, in the client route registry's vocabulary
              (`FIGHTER` once Fighter onboarding is complete, `COACH` once Coach onboarding is complete,
              `GYM_WORKSPACE` while the viewer is active staff at a gym with a completed setup, `SPONSOR_WORKSPACE`
              while the viewer is an active member of an active sponsor organization; any combination can be held).
              Registration intent never grants `SPONSOR_WORKSPACE`. A routing projection, not an authorization grant: `COACH` opens the user's own Coach
              application only, and gym access is decided per gym by its path.
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
          capabilities: ["COACH"],
          gym_id: nil,
          gym_workspaces: [],
          gym_workspace_count: 0,
          sponsor_id: nil,
          sponsor_workspaces: [],
          sponsor_workspace_count: 0
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
      description: """
      The context the viewer chose: a completed profile, a gym workspace (with `gym_id`) with a completed setup
      where the viewer is active staff, or a sponsor workspace (with `sponsor_id`) where the viewer is an active
      member of the active organization.
      """,
      type: :object,
      required: [:context],
      additionalProperties: false,
      properties: %{
        context: %Schema{
          type: :string,
          enum: Enum.map(Entry.contexts(), &Atom.to_string/1),
          description:
            "`fighter`, `coach`, `gym` (with `gym_id`) or `sponsor` (with `sponsor_id`)."
        },
        gym_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Required with `context: gym`, rejected otherwise."
        },
        sponsor_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Required with `context: sponsor`, rejected otherwise."
        }
      },
      example: %{context: "gym", gym_id: "4b2c1a7e-1f0a-4c8e-9a52-0d6f3c1b9e21"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EntryGymWorkspace do
  @moduledoc "OpenAPI schema: one of the viewer's gym workspaces in the entry answer (SF-84)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.StaffMembership

  OpenApiSpex.schema(
    %{
      title: "EntryGymWorkspace",
      description: """
      A gym where the viewer holds an active staff membership: only the gym's name and the viewer's own facts
      there. No member, staff, booking, revenue, plan, verification or publication data exists here.
      """,
      type: :object,
      additionalProperties: false,
      required: [:available_actions, :gym_id, :name, :role, :selected, :setup_status],
      properties: %{
        gym_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        role: %Schema{type: :string, enum: Enum.map(StaffMembership.roles(), &Atom.to_string/1)},
        setup_status: %Schema{
          type: :string,
          enum: ["draft", "completed"],
          description:
            "A `draft` gym is not an operational workspace yet; only its setup can continue."
        },
        available_actions: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ["enter", "continue_setup"]},
          description: """
          What the viewer can do from a chooser, decided by the backend: `enter` a completed gym, or
          `continue_setup` of a draft (the role that completes setup). Empty when neither applies.
          """
        },
        selected: %Schema{
          type: :boolean,
          description: "This gym is the viewer's remembered choice and is still valid."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.EntrySponsorWorkspace do
  @moduledoc "OpenAPI schema: one of the viewer's sponsor workspaces in the entry answer (SF-112)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "EntrySponsorWorkspace",
      description: """
      An active sponsor organization where the viewer holds an active membership: only its display name and the
      viewer's own role. No member, contact, application, campaign, plan or commercial data exists here.
      """,
      type: :object,
      additionalProperties: false,
      required: [:display_name, :role, :selected, :sponsor_id],
      properties: %{
        sponsor_id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string},
        role: %Schema{type: :string, enum: ["owner", "manager", "member"]},
        selected: %Schema{
          type: :boolean,
          description: "This organization is the viewer's remembered choice and is still valid."
        }
      }
    },
    struct?: false
  )
end
