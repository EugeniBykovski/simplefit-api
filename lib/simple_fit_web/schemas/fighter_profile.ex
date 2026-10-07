defmodule SimpleFitWeb.Schemas.FighterProfileFields do
  @moduledoc """
  Shared OpenAPI property definitions of the fighter profile (ADR 0015).
  Vocabularies come from `SimpleFit.Fighters.FighterProfile`, so the contract
  cannot drift from what the domain accepts.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Fighters.FighterProfile

  defp enum(values), do: Enum.map(values, &Atom.to_string/1)

  @doc false
  def properties do
    %{
      display_name: %Schema{
        type: :string,
        nullable: true,
        minLength: 1,
        maxLength: 80,
        description: "Name shown to teammates and coaches (OF1). Trimmed.",
        example: "Yauheni B."
      },
      username: %Schema{
        type: :string,
        nullable: true,
        pattern: "^[A-Za-z][A-Za-z0-9_]{2,29}$",
        description: """
        Unique handle without the `@` (OF1). Stored and returned in lowercase: a letter, then 2-29 letters,
        digits or underscores. A handle another fighter holds is rejected with `already_exists`.
        """,
        example: "yauheni"
      },
      country_code: %Schema{
        type: :string,
        nullable: true,
        pattern: "^[A-Za-z]{2}$",
        description: "ISO 3166-1 alpha-2 country (OF1). Returned in uppercase.",
        example: "PL"
      },
      city: %Schema{
        type: :string,
        nullable: true,
        minLength: 1,
        maxLength: 100,
        description: "City (OF1). Trimmed.",
        example: "Warsaw"
      },
      experience_level: %Schema{
        type: :string,
        nullable: true,
        enum: enum(FighterProfile.experience_levels()),
        description: "Boxing experience (OF2).",
        example: "competitive_amateur"
      },
      bout_count: %Schema{
        type: :integer,
        nullable: true,
        minimum: 0,
        maximum: 500,
        description:
          "Amateur bouts (OF2). Only with `experience_level: competitive_amateur`; cleared when the level changes.",
        example: 14
      },
      stance: %Schema{
        type: :string,
        nullable: true,
        enum: enum(FighterProfile.stances()),
        description: "Stance (OF2).",
        example: "orthodox"
      },
      goals: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: enum(FighterProfile.goals())},
        uniqueItems: true,
        description: "Training goals, any number, no repeats (OF3).",
        example: ["improve_technique", "competition"]
      },
      next_fight_on: %Schema{
        type: :string,
        format: :date,
        nullable: true,
        description: "Date of the next fight (OF3, optional).",
        example: "2026-11-03"
      },
      next_fight_name: %Schema{
        type: :string,
        nullable: true,
        minLength: 1,
        maxLength: 120,
        description: "Event of the next fight (OF3, optional). Requires `next_fight_on`.",
        example: "Warsaw Cup"
      },
      weight_class: %Schema{
        type: :string,
        nullable: true,
        enum: enum(FighterProfile.weight_classes()),
        description: """
        Approximate weight class in kg (OF4): `minus_63_5` is −63.5, `plus_86` is +86. Private: never shown
        to other users.
        """,
        example: "minus_75"
      },
      current_weight_kg: %Schema{
        type: :number,
        nullable: true,
        minimum: 30,
        maximum: 200,
        description: "Current weight in kg, one decimal (OF4, optional). Private.",
        example: 73.8
      },
      height_cm: %Schema{
        type: :integer,
        nullable: true,
        minimum: 120,
        maximum: 230,
        description: "Height in cm (OF4, optional). Private.",
        example: 178
      }
    }
  end

  @doc false
  def requirement_names, do: enum(FighterProfile.required_fields())
end

defmodule SimpleFitWeb.Schemas.FighterProfileUpdateRequest do
  @moduledoc "OpenAPI schema: save Fighter onboarding progress."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.FighterProfileFields

  OpenApiSpex.schema(
    %{
      title: "FighterProfileUpdateRequest",
      description: """
      Any subset of the fighter profile. Omitted fields are unchanged; `null` clears a field. Nothing is
      required while onboarding is in progress. After completion the required fields can be changed but not
      cleared.
      """,
      type: :object,
      additionalProperties: false,
      properties: FighterProfileFields.properties(),
      example: %{
        experience_level: "competitive_amateur",
        bout_count: 14,
        stance: "orthodox"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.FighterProfileResponse do
  @moduledoc "OpenAPI schema: the authenticated user's fighter profile and onboarding state."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.FighterProfileFields

  @fields FighterProfileFields.properties()

  OpenApiSpex.schema(
    %{
      title: "FighterProfileResponse",
      description: """
      Always returned, also before onboarding has started (`status: not_started`, every field empty), so a
      client can render onboarding from this response alone. Body data is included only because the viewer
      is the profile's owner.
      """,
      type: :object,
      required: [:fighter_profile],
      additionalProperties: false,
      properties: %{
        fighter_profile: %Schema{
          type: :object,
          required: Enum.sort([:onboarding | Map.keys(@fields)]),
          additionalProperties: false,
          properties:
            Map.put(@fields, :onboarding, %Schema{
              type: :object,
              required: [:status, :completed_at, :missing_requirements],
              additionalProperties: false,
              properties: %{
                status: %Schema{
                  type: :string,
                  enum: ["not_started", "in_progress", "completed"],
                  description: """
                  `not_started`: no fighter profile yet. `in_progress`: progress saved, not completed.
                  `completed`: completion recorded by `completeFighterOnboarding`.
                  """
                },
                completed_at: %Schema{
                  type: :string,
                  format: :"date-time",
                  nullable: true,
                  description: "When onboarding was completed; `null` until then."
                },
                missing_requirements: %Schema{
                  type: :array,
                  items: %Schema{type: :string, enum: FighterProfileFields.requirement_names()},
                  description:
                    "Required fields still empty, in step order. Completion succeeds only when this is empty."
                }
              }
            })
        }
      },
      example: %{
        fighter_profile: %{
          onboarding: %{
            status: "in_progress",
            completed_at: nil,
            missing_requirements: ["country_code", "city"]
          },
          display_name: "Yauheni B.",
          username: "yauheni",
          country_code: nil,
          city: nil,
          experience_level: "competitive_amateur",
          bout_count: 14,
          stance: "orthodox",
          goals: ["improve_technique", "competition", "fight_preparation"],
          next_fight_on: "2026-11-03",
          next_fight_name: "Warsaw Cup",
          weight_class: "minus_75",
          current_weight_kg: 73.8,
          height_cm: 178
        }
      }
    },
    struct?: false
  )
end
