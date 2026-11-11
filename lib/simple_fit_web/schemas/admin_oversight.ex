defmodule SimpleFitWeb.Schemas.AdminOversightEnums do
  @moduledoc false
  # The enums SF-123's oversight schemas share, read from the domain so they can't drift.

  alias SimpleFit.Coaches.CoachProfile
  alias SimpleFit.Fighters.FighterProfile
  alias SimpleFit.Gyms.Gym

  def gym_types, do: strings(Ecto.Enum.values(Gym, :gym_type))
  def lifecycles, do: strings(Ecto.Enum.values(Gym, :setup_status))
  def verification_statuses, do: strings(SimpleFit.Gyms.oversight_verification_statuses())
  def profile_statuses, do: ~w(in_progress completed)
  def account_statuses, do: ~w(active suspended)
  def experience_levels, do: strings(Ecto.Enum.values(FighterProfile, :experience_level))
  def stances, do: strings(Ecto.Enum.values(FighterProfile, :stance))
  def languages, do: strings(Ecto.Enum.values(CoachProfile, :languages))
  def coaching_formats, do: strings(Ecto.Enum.values(CoachProfile, :coaching_formats))
  def competition_levels, do: strings(Ecto.Enum.values(CoachProfile, :competition_levels))

  defp strings(values), do: Enum.map(values, &Atom.to_string/1)
end

defmodule SimpleFitWeb.Schemas.AdminGymSummary do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminOversightEnums, as: Enums

  OpenApiSpex.schema(%{
    title: "AdminGymSummary",
    description:
      "One gym in the operator list (SF-123): its own state, never its people. `lifecycle` is the gym's " <>
        "setup; there is no suspension, closure or publication state.",
    type: :object,
    required: [
      :id,
      :name,
      :gym_type,
      :lifecycle,
      :verification_status,
      :country_code,
      :city,
      :staff_count,
      :created_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string},
      gym_type: %Schema{type: :string, enum: Enums.gym_types()},
      lifecycle: %Schema{type: :string, enum: Enums.lifecycles()},
      verification_status: %Schema{
        type: :string,
        enum: Enums.verification_statuses(),
        description: "The business verification application's status (SF-103), or `not_started`."
      },
      country_code: %Schema{
        type: :string,
        nullable: true,
        description: "The primary location's country (ISO alpha-2); none before setup adds one."
      },
      city: %Schema{type: :string, nullable: true},
      staff_count: %Schema{
        type: :integer,
        minimum: 0,
        description: "Active staff, the owner included."
      },
      created_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminGymListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminGymSummary

  OpenApiSpex.schema(%{
    title: "AdminGymListResponse",
    description: "One page of gyms, newest first.",
    type: :object,
    required: [:gyms, :next_cursor],
    properties: %{
      gyms: %Schema{type: :array, items: AdminGymSummary, maxItems: 50},
      next_cursor: %Schema{
        type: :string,
        nullable: true,
        description:
          "The next page, for the same filters and reader only; `null` on the last page."
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminGym do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminGymSummary
  alias SimpleFitWeb.Schemas.AdminOversightEnums, as: Enums

  OpenApiSpex.schema(%{
    title: "AdminGym",
    description: """
    One gym for operators (SF-123), read in one snapshot. People are counts, plus the owner's user id and
    short name ("Natalia W."): never member names, contact details or staff lists. Verification is the
    application's status, revision and dates: never its declared business details or documents.
    """,
    type: :object,
    required:
      AdminGymSummary.schema().required ++
        [:revision, :owner, :staff, :staff_invitations_pending, :members, :verification],
    properties:
      Map.merge(AdminGymSummary.schema().properties, %{
        revision: %Schema{type: :integer, minimum: 1},
        owner: %Schema{
          type: :object,
          nullable: true,
          required: [:user_id, :short_name],
          properties: %{
            user_id: %Schema{
              type: :string,
              format: :uuid,
              description: "Opening the account needs `users.read`."
            },
            short_name: %Schema{type: :string, nullable: true}
          }
        },
        staff: %Schema{
          type: :object,
          description: "Active staff by role, the owner excluded.",
          required: [:manager, :coach, :front_desk],
          properties: %{
            manager: %Schema{type: :integer, minimum: 0},
            coach: %Schema{type: :integer, minimum: 0},
            front_desk: %Schema{type: :integer, minimum: 0}
          }
        },
        staff_invitations_pending: %Schema{type: :integer, minimum: 0},
        members: %Schema{
          type: :object,
          description: "Gym members by status: counts only.",
          required: [:active, :requested],
          properties: %{
            active: %Schema{type: :integer, minimum: 0},
            requested: %Schema{type: :integer, minimum: 0}
          }
        },
        verification: %Schema{
          type: :object,
          required: [:status, :revision, :submitted_at, :decided_at],
          properties: %{
            status: %Schema{
              type: :string,
              enum: Enums.verification_statuses()
            },
            revision: %Schema{type: :integer, nullable: true},
            submitted_at: %Schema{type: :string, format: :"date-time", nullable: true},
            decided_at: %Schema{type: :string, format: :"date-time", nullable: true}
          }
        }
      })
  })
end

defmodule SimpleFitWeb.Schemas.AdminGymResponse do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.AdminGym

  OpenApiSpex.schema(%{
    title: "AdminGymResponse",
    type: :object,
    required: [:gym],
    properties: %{gym: AdminGym}
  })
end

defmodule SimpleFitWeb.Schemas.AdminCoachSummary do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminOversightEnums, as: Enums

  OpenApiSpex.schema(%{
    title: "AdminCoachSummary",
    description: "A coach found by exact search.",
    type: :object,
    required: [
      :id,
      :user_id,
      :display_name,
      :brand_name,
      :profile_status,
      :account_status,
      :active_relationships
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid, description: "The coach profile."},
      user_id: %Schema{type: :string, format: :uuid},
      display_name: %Schema{type: :string, nullable: true},
      brand_name: %Schema{type: :string, nullable: true},
      profile_status: %Schema{type: :string, enum: Enums.profile_statuses()},
      account_status: %Schema{type: :string, enum: Enums.account_statuses()},
      active_relationships: %Schema{type: :integer, minimum: 0}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminCoachSearchResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminCoachSummary

  OpenApiSpex.schema(%{
    title: "AdminCoachSearchResponse",
    description: "At most one coach: search is exact, never a list.",
    type: :object,
    required: [:coaches],
    properties: %{coaches: %Schema{type: :array, items: AdminCoachSummary, maxItems: 1}}
  })
end

defmodule SimpleFitWeb.Schemas.AdminCoach do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminOversightEnums, as: Enums

  OpenApiSpex.schema(%{
    title: "AdminCoach",
    description: """
    One coach for operators (SF-123). The coach profile's onboarding (`profile_status`) and the account's
    state (`account_status`) are separate. Relationships are counts only: never who the fighters are, their
    training, notes or messages. Coaches have no verification state. `gyms` are the gyms they coach at
    (staff membership as coach), ids only: opening one needs `gyms.read`.
    """,
    type: :object,
    required: [
      :id,
      :user_id,
      :display_name,
      :brand_name,
      :country_code,
      :city,
      :languages,
      :coaching_formats,
      :competition_levels,
      :profile_status,
      :account_status,
      :created_at,
      :relationships,
      :gyms
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      user_id: %Schema{
        type: :string,
        format: :uuid,
        description: "Opening the account needs `users.read`."
      },
      display_name: %Schema{type: :string, nullable: true},
      brand_name: %Schema{type: :string, nullable: true},
      country_code: %Schema{type: :string, nullable: true},
      city: %Schema{type: :string, nullable: true},
      languages: %Schema{type: :array, items: %Schema{type: :string, enum: Enums.languages()}},
      coaching_formats: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: Enums.coaching_formats()}
      },
      competition_levels: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: Enums.competition_levels()}
      },
      profile_status: %Schema{type: :string, enum: Enums.profile_statuses()},
      account_status: %Schema{type: :string, enum: Enums.account_statuses()},
      created_at: %Schema{type: :string, format: :"date-time"},
      relationships: %Schema{
        type: :object,
        required: [:active, :ended, :invitations_pending],
        properties: %{
          active: %Schema{type: :integer, minimum: 0},
          ended: %Schema{type: :integer, minimum: 0},
          invitations_pending: %Schema{type: :integer, minimum: 0}
        }
      },
      gyms: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          required: [:gym_id, :since],
          properties: %{
            gym_id: %Schema{type: :string, format: :uuid},
            since: %Schema{type: :string, format: :"date-time"}
          }
        }
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminCoachResponse do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.AdminCoach

  OpenApiSpex.schema(%{
    title: "AdminCoachResponse",
    type: :object,
    required: [:coach],
    properties: %{coach: AdminCoach}
  })
end

defmodule SimpleFitWeb.Schemas.AdminFighterSummary do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminOversightEnums, as: Enums

  OpenApiSpex.schema(%{
    title: "AdminFighterSummary",
    description: "A fighter found by exact search.",
    type: :object,
    required: [
      :id,
      :user_id,
      :display_name,
      :username,
      :profile_status,
      :account_status,
      :active_relationships
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid, description: "The fighter profile."},
      user_id: %Schema{type: :string, format: :uuid},
      display_name: %Schema{type: :string, nullable: true},
      username: %Schema{type: :string, nullable: true},
      profile_status: %Schema{type: :string, enum: Enums.profile_statuses()},
      account_status: %Schema{type: :string, enum: Enums.account_statuses()},
      active_relationships: %Schema{type: :integer, minimum: 0}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminFighterSearchResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminFighterSummary

  OpenApiSpex.schema(%{
    title: "AdminFighterSearchResponse",
    description: "At most one fighter: search is exact, never a list.",
    type: :object,
    required: [:fighters],
    properties: %{fighters: %Schema{type: :array, items: AdminFighterSummary, maxItems: 1}}
  })
end

defmodule SimpleFitWeb.Schemas.AdminFighter do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminOversightEnums, as: Enums

  OpenApiSpex.schema(%{
    title: "AdminFighter",
    description: """
    One fighter for operators (SF-123): the fields a fighter shares with a coach they accept (without the
    bout count), onboarding (`profile_status`) and the account's state (`account_status`), separately.
    Relationships and gym memberships are counts only. Never weight, height, weight class, goals, fights,
    age or date of birth, health, training, notes or messages: no permission exists for them.
    """,
    type: :object,
    required: [
      :id,
      :user_id,
      :display_name,
      :username,
      :country_code,
      :city,
      :experience_level,
      :stance,
      :profile_status,
      :account_status,
      :created_at,
      :relationships,
      :gym_memberships
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      user_id: %Schema{
        type: :string,
        format: :uuid,
        description: "Opening the account needs `users.read`."
      },
      display_name: %Schema{type: :string, nullable: true},
      username: %Schema{type: :string, nullable: true},
      country_code: %Schema{type: :string, nullable: true},
      city: %Schema{type: :string, nullable: true},
      experience_level: %Schema{type: :string, nullable: true, enum: Enums.experience_levels()},
      stance: %Schema{type: :string, nullable: true, enum: Enums.stances()},
      profile_status: %Schema{type: :string, enum: Enums.profile_statuses()},
      account_status: %Schema{type: :string, enum: Enums.account_statuses()},
      created_at: %Schema{type: :string, format: :"date-time"},
      relationships: %Schema{
        type: :object,
        required: [:active, :ended],
        properties: %{
          active: %Schema{type: :integer, minimum: 0},
          ended: %Schema{type: :integer, minimum: 0}
        }
      },
      gym_memberships: %Schema{
        type: :integer,
        minimum: 0,
        description: "Active gym memberships: a count, never which gyms."
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminFighterResponse do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.AdminFighter

  OpenApiSpex.schema(%{
    title: "AdminFighterResponse",
    type: :object,
    required: [:fighter],
    properties: %{fighter: AdminFighter}
  })
end
