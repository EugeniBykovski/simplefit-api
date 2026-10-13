defmodule SimpleFitWeb.Schemas.CoachProfileFields do
  @moduledoc """
  Shared OpenAPI property definitions of the coach profile (ADR 0020).
  Vocabularies come from `SimpleFit.Coaches.CoachProfile`, so the contract
  cannot drift from what the domain accepts.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Coaches.CoachProfile

  defp enum(values), do: Enum.map(values, &Atom.to_string/1)

  defp selection(values, description, example) do
    %Schema{
      type: :array,
      items: %Schema{type: :string, enum: enum(values)},
      uniqueItems: true,
      nullable: true,
      description: description,
      example: example
    }
  end

  @doc false
  def properties do
    %{
      display_name: %Schema{
        type: :string,
        nullable: true,
        minLength: 1,
        maxLength: 60,
        description: """
        Public coach name. Trimmed; 1-60 characters, no control characters. Owned by the coach profile:
        never copied from the account's full name or the fighter profile, and changing either never changes
        it. Required to complete onboarding.
        """,
        example: "Coach Marek"
      },
      brand_name: %Schema{
        type: :string,
        nullable: true,
        minLength: 1,
        maxLength: 80,
        description: "Optional public coaching brand. Trimmed; 1-80 characters.",
        example: "Marek Boxing"
      },
      country_code: %Schema{
        type: :string,
        nullable: true,
        pattern: "^\\s*[A-Za-z]{2}\\s*$",
        description: """
        Country as an officially assigned ISO 3166-1 alpha-2 code (same list as the fighter profile).
        Trimmed and returned in uppercase; codes that are not assigned are rejected with `invalid_choice`.
        Required to complete onboarding.
        """,
        example: "PL"
      },
      city: %Schema{
        type: :string,
        nullable: true,
        minLength: 1,
        maxLength: 80,
        description: "City. Trimmed; 1-80 characters. Required to complete onboarding.",
        example: "Warsaw"
      },
      bio: %Schema{
        type: :string,
        nullable: true,
        minLength: 1,
        maxLength: 500,
        description:
          "Optional public bio, plain text. Trimmed; up to 500 characters; line breaks allowed.",
        example: "Footwork-first boxing. I run 10-week fight camps for amateurs."
      },
      languages:
        selection(
          CoachProfile.languages(),
          """
          Languages the coach coaches in (ISO 639-1; spoken languages, not app locales). Any number; a repeated
          value is rejected with `invalid`; `null` or `[]` clears.
          """,
          ["pl", "en"]
        ),
      coaching_formats:
        selection(
          CoachProfile.coaching_formats(),
          """
          How the coach works. Any number; a repeated value is rejected with `invalid`; `null` or `[]` clears. At least one is required to
          complete onboarding, and a completed profile cannot clear them all.
          """,
          ["personal_training", "fight_camps"]
        ),
      competition_levels:
        selection(
          CoachProfile.competition_levels(),
          """
          Optional competitive levels of the fighters the coach prepares (same keys as the fighter
          profile's experience levels). Any number; a repeated value is rejected with `invalid`; `null` or
          `[]` clears.
          """,
          ["amateur"]
        )
    }
  end

  @doc false
  def requirement_names, do: enum(CoachProfile.required_fields())
end

defmodule SimpleFitWeb.Schemas.CoachProfileUpdateRequest do
  @moduledoc "OpenAPI schema: save Coach onboarding progress."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.CoachProfileFields

  OpenApiSpex.schema(
    %{
      title: "CoachProfileUpdateRequest",
      description: """
      Any subset of the coach profile. Omitted fields are unchanged; `null` (or an empty or blank text, or
      `[]` for a selection) clears a field. Nothing is required while onboarding is in progress and saving
      never completes it. After completion the required fields can be changed but not cleared. A field
      outside this schema (for example `user_id`, `coach_id`, `gym_id` or `onboarding_completed_at`) is
      rejected with `422 validation_error`, code `invalid` under that field name, and nothing is saved.
      """,
      type: :object,
      additionalProperties: false,
      properties: CoachProfileFields.properties(),
      example: %{
        display_name: "Coach Marek",
        country_code: "PL",
        city: "Warsaw",
        coaching_formats: ["personal_training", "group_coaching"]
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachProfileResponse do
  @moduledoc "OpenAPI schema: the authenticated user's coach profile and onboarding state."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.CoachProfileFields

  @fields CoachProfileFields.properties()
          |> Map.new(fn
            {key, %Schema{type: :array} = schema} -> {key, %{schema | nullable: false}}
            entry -> entry
          end)

  OpenApiSpex.schema(
    %{
      title: "CoachProfileResponse",
      description: """
      Always returned, also before onboarding has started (`status: not_started`, every field empty), so a
      client can render and resume onboarding from this response alone. Selections are always arrays.
      """,
      type: :object,
      required: [:coach_profile],
      additionalProperties: false,
      properties: %{
        coach_profile: %Schema{
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
                  `not_started`: no coach profile yet. `in_progress`: progress saved, not completed (also when
                  every required field is present). `completed`: completion recorded by
                  `completeMyCoachOnboarding`.
                  """
                },
                completed_at: %Schema{
                  type: :string,
                  format: :"date-time",
                  nullable: true,
                  description:
                    "When onboarding was completed; `null` until then. Never changes afterwards."
                },
                missing_requirements: %Schema{
                  type: :array,
                  items: %Schema{type: :string, enum: CoachProfileFields.requirement_names()},
                  description:
                    "Required fields still empty, in step order. Completion succeeds only when this is empty."
                }
              }
            })
        }
      },
      example: %{
        coach_profile: %{
          onboarding: %{
            status: "in_progress",
            completed_at: nil,
            missing_requirements: ["coaching_formats"]
          },
          display_name: "Coach Marek",
          brand_name: nil,
          country_code: "PL",
          city: "Warsaw",
          bio: nil,
          languages: ["pl", "en"],
          coaching_formats: [],
          competition_levels: []
        }
      }
    },
    struct?: false
  )
end
