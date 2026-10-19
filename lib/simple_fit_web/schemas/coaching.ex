defmodule SimpleFitWeb.Schemas.CoachingFields do
  @moduledoc """
  Shared OpenAPI definitions of Coach–Fighter relationships (ADR 0021).
  Vocabularies come from the domain (`SimpleFit.Fighters`,
  `SimpleFit.Fighters.FighterProfile`), so the contract cannot drift from
  what the backend discloses.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Fighters
  alias SimpleFit.Fighters.FighterProfile

  defp enum(values), do: Enum.map(values, &Atom.to_string/1)

  @doc "Properties every relationship entry shares, for either side."
  def lifecycle do
    %{
      relationship_id: %Schema{
        type: :string,
        format: :uuid,
        description: "The relationship. The only handle either side uses to address it."
      },
      status: %Schema{
        type: :string,
        enum: ["active", "ended"],
        description:
          "`active` until either side ends it; `ended` is final (a reconnection is a new relationship)."
      },
      started_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "When the fighter accepted the relationship."
      },
      ended_at: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the relationship ended; `null` while active."
      },
      ended_by: %Schema{
        type: :string,
        # `null` is listed so strict validators accept a nullable enum.
        enum: ["coach", "fighter", nil],
        nullable: true,
        description: "Which side ended it; `null` while active."
      }
    }
  end

  @doc "The fighter profile fields a relationship can ever disclose (C1 + C2)."
  def disclosed_fields do
    %Schema{
      type: :array,
      items: %Schema{type: :string, enum: enum(Fighters.coach_visible_fields())},
      description: """
      The fighter profile fields disclosed under `disclosure_version`, as the backend applies it today: never
      more than the fighter accepted. Empty when the relationship has ended or the version is no longer offered.
      """
    }
  end

  @doc "The disclosure version the fighter accepted."
  def disclosure_version(nullable?) do
    %Schema{
      type: :string,
      nullable: nullable?,
      description:
        "The disclosure version the fighter accepted (identifier of the approved legal text)."
    }
  end

  @doc "The C1 + C2 fighter projection a coach sees."
  def fighter do
    %Schema{
      type: :object,
      nullable: true,
      additionalProperties: false,
      required: Enum.sort(Fighters.coach_visible_fields()),
      description: """
      The fighter as disclosed to the coach: only the fields listed in `disclosed_fields` carry values, every
      other one is `null`. Never contains goals, next fight, weight, height, account name, date of birth, email
      or any other personal data. `null` for an ended relationship.
      """,
      properties: %{
        display_name: %Schema{type: :string, nullable: true, example: "Alex K."},
        username: %Schema{type: :string, nullable: true, example: "alex_k"},
        country_code: %Schema{type: :string, nullable: true, example: "PL"},
        city: %Schema{type: :string, nullable: true, example: "Warsaw"},
        experience_level: %Schema{
          type: :string,
          nullable: true,
          enum: enum(FighterProfile.experience_levels()) ++ [nil],
          example: "amateur"
        },
        stance: %Schema{
          type: :string,
          nullable: true,
          enum: enum(FighterProfile.stances()) ++ [nil],
          example: "orthodox"
        },
        amateur_bout_count: %Schema{type: :integer, nullable: true, minimum: 0, example: 14}
      }
    }
  end

  @doc "The coach's public identity a fighter sees."
  def coach do
    %Schema{
      type: :object,
      nullable: true,
      additionalProperties: false,
      required: [:brand_name, :display_name],
      description: "The coach's public identity, current; `null` for an ended relationship.",
      properties: %{
        display_name: %Schema{type: :string, nullable: true, example: "Coach Marek"},
        brand_name: %Schema{type: :string, nullable: true, example: "Marek Boxing"}
      }
    }
  end

  @doc "The pagination cursor of a list response."
  def next_cursor do
    %Schema{
      type: :string,
      nullable: true,
      description: "Pass as `cursor` to read the next page; `null` on the last page. Opaque."
    }
  end
end

defmodule SimpleFitWeb.Schemas.CoachFighterRelationship do
  @moduledoc "OpenAPI schema: one relationship as its coach sees it."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.CoachingFields

  @properties CoachingFields.lifecycle()
              |> Map.merge(%{
                disclosure_version: CoachingFields.disclosure_version(true),
                disclosed_fields: CoachingFields.disclosed_fields(),
                fighter: CoachingFields.fighter(),
                fighter_display_name_at_end: %Schema{
                  type: :string,
                  nullable: true,
                  description: """
                  The fighter's display name as it was when the relationship ended (the only fighter data kept
                  for the coach afterwards); `null` while active.
                  """
                }
              })

  OpenApiSpex.schema(
    %{
      title: "CoachFighterRelationship",
      description: """
      A coaching relationship seen by its coach. While `active`: the fighter fields of the accepted disclosure
      version. Once `ended`: a stub (dates, who ended it, the fighter's name at the end) and no profile data.
      """,
      type: :object,
      additionalProperties: false,
      required: @properties |> Map.keys() |> Enum.sort(),
      properties: @properties,
      example: %{
        relationship_id: "5b0a3c1e-2f43-4d0e-9a51-7f6d2c8e1b90",
        status: "active",
        started_at: "2026-10-15T09:00:00.000000Z",
        ended_at: nil,
        ended_by: nil,
        disclosure_version: "fighter-disclosure-v1",
        disclosed_fields: ~w(display_name username country_code city experience_level stance
                             amateur_bout_count),
        fighter: %{
          display_name: "Alex K.",
          username: "alex_k",
          country_code: "PL",
          city: "Warsaw",
          experience_level: "competitive_amateur",
          stance: "orthodox",
          amateur_bout_count: 14
        },
        fighter_display_name_at_end: nil
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachFighterRelationshipResponse do
  @moduledoc "OpenAPI schema: one active relationship of the coach."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.CoachFighterRelationship

  OpenApiSpex.schema(
    %{
      title: "CoachFighterRelationshipResponse",
      type: :object,
      additionalProperties: false,
      required: [:relationship],
      properties: %{relationship: CoachFighterRelationship}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachFighterRelationshipList do
  @moduledoc "OpenAPI schema: one page of the coach's relationships."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{CoachFighterRelationship, CoachingFields}

  OpenApiSpex.schema(
    %{
      title: "CoachFighterRelationshipList",
      type: :object,
      additionalProperties: false,
      required: [:next_cursor, :relationships],
      properties: %{
        relationships: %Schema{
          type: :array,
          items: CoachFighterRelationship,
          description: "Newest first. Empty when the coach has none (a real, empty roster)."
        },
        next_cursor: CoachingFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyCoachRelationship do
  @moduledoc "OpenAPI schema: one relationship as its fighter sees it."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.CoachingFields

  @properties CoachingFields.lifecycle()
              |> Map.merge(%{
                disclosure_version: CoachingFields.disclosure_version(false),
                disclosed_fields: CoachingFields.disclosed_fields(),
                coach: CoachingFields.coach(),
                coach_display_name_at_end: %Schema{
                  type: :string,
                  nullable: true,
                  description:
                    "The coach's display name as it was when the relationship ended; `null` while active."
                }
              })

  OpenApiSpex.schema(
    %{
      title: "MyCoachRelationship",
      description: """
      One of the viewer's coaching relationships, seen by the fighter: the coach's public identity and the
      fields of the viewer's profile it discloses while `active`; the coach's name at the end once `ended`.
      """,
      type: :object,
      additionalProperties: false,
      required: @properties |> Map.keys() |> Enum.sort(),
      properties: @properties,
      example: %{
        relationship_id: "5b0a3c1e-2f43-4d0e-9a51-7f6d2c8e1b90",
        status: "active",
        started_at: "2026-10-15T09:00:00.000000Z",
        ended_at: nil,
        ended_by: nil,
        disclosure_version: "fighter-disclosure-v1",
        disclosed_fields: ~w(display_name username country_code city experience_level stance
                             amateur_bout_count),
        coach: %{display_name: "Coach Marek", brand_name: "Marek Boxing"},
        coach_display_name_at_end: nil
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyCoachRelationshipResponse do
  @moduledoc "OpenAPI schema: one relationship of the viewer as fighter (SF-74)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.MyCoachRelationship

  OpenApiSpex.schema(
    %{
      title: "MyCoachRelationshipResponse",
      type: :object,
      additionalProperties: false,
      required: [:relationship],
      properties: %{relationship: MyCoachRelationship}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyCoachRelationshipList do
  @moduledoc "OpenAPI schema: one page of the fighter's own relationships."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{CoachingFields, MyCoachRelationship}

  OpenApiSpex.schema(
    %{
      title: "MyCoachRelationshipList",
      type: :object,
      additionalProperties: false,
      required: [:next_cursor, :relationships],
      properties: %{
        relationships: %Schema{
          type: :array,
          items: MyCoachRelationship,
          description: "Newest first. Empty when the fighter has none."
        },
        next_cursor: CoachingFields.next_cursor()
      }
    },
    struct?: false
  )
end
