defmodule SimpleFitWeb.Schemas.GymFields do
  @moduledoc """
  Shared OpenAPI definitions of gyms (ADR 0026). Vocabularies come from the
  `SimpleFit.Gyms` schemas and policy, so the contract cannot drift from
  what the backend accepts and decides.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.{Gym, Policy, StaffMembership}

  @doc "The gym type vocabulary (D-G13)."
  def gym_type do
    %Schema{
      type: :string,
      enum: Enum.map(Gym.gym_types(), &Atom.to_string/1),
      description:
        "One of six gym types: boxing gym, boxing club, amateur club, professional team, combat sports gym, " <>
          "fitness boxing studio."
    }
  end

  @doc "The gym name."
  def name,
    do: %Schema{
      type: :string,
      minLength: 1,
      maxLength: 80,
      description: "Trimmed; 1–80 characters without control characters.",
      example: "Simple Boxing Gym"
    }

  @doc "The viewer's own staff membership at the gym and what it allows."
  def viewer do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:permissions, :role, :staff_membership_id],
      description: """
      The viewer's active staff membership at this gym. `permissions` is a read-only projection of the fixed
      role matrix for display; the server checks every operation itself, and some permissions are limited to a
      scope the operation enforces (for example a coach's own classes).
      """,
      properties: %{
        staff_membership_id: %Schema{type: :string, format: :uuid},
        role: %Schema{type: :string, enum: Enum.map(StaffMembership.roles(), &Atom.to_string/1)},
        permissions: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: Enum.map(Policy.permissions(), &Atom.to_string/1)}
        }
      }
    }
  end

  @doc "The properties every gym view has."
  def gym do
    %{
      id: %Schema{type: :string, format: :uuid},
      name: name(),
      gym_type: gym_type(),
      setup_status: %Schema{
        type: :string,
        enum: ["draft", "completed"],
        description: """
        `draft` from creation until the backend's setup checks pass, then `completed` (final). A draft is
        private to its staff and never public.
        """
      },
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"},
      viewer: viewer()
    }
  end

  @doc "The `next_cursor` of a page."
  def next_cursor do
    %Schema{
      type: :string,
      nullable: true,
      description: "Pass as `cursor` to read the next page; `null` on the last page. Opaque."
    }
  end
end

defmodule SimpleFitWeb.Schemas.GymCreateRequest do
  @moduledoc "OpenAPI schema: create a draft gym."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymFields

  OpenApiSpex.schema(
    %{
      title: "GymCreateRequest",
      description: """
      The first valid submission of gym creation. The viewer becomes the owner; no owner, role, status or other
      field is accepted.
      """,
      type: :object,
      additionalProperties: false,
      required: [:client_request_id, :gym_type, :name],
      properties: %{
        client_request_id: %Schema{
          type: :string,
          format: :uuid,
          description:
            "Chosen by the client for one create and repeated on a retry (idempotency key)."
        },
        name: GymFields.name(),
        gym_type: GymFields.gym_type()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymLocation do
  @moduledoc "OpenAPI schema: an address-only gym location."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GymLocation",
      description: "An address-only place of the gym (no map, geocoding or tracking).",
      type: :object,
      additionalProperties: false,
      required: [:address_line, :city, :country_code, :entrance_note, :id, :is_primary, :name],
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        country_code: %Schema{type: :string, description: "ISO 3166-1 alpha-2."},
        city: %Schema{type: :string},
        address_line: %Schema{type: :string},
        entrance_note: %Schema{type: :string, nullable: true},
        is_primary: %Schema{type: :boolean}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.Gym do
  @moduledoc "OpenAPI schema: one gym as one of its staff sees it."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymLocation}

  @properties Map.put(GymFields.gym(), :locations, %Schema{
                type: :array,
                items: GymLocation,
                description: "Non-archived locations, primary first. Empty until setup adds one."
              })

  OpenApiSpex.schema(
    %{
      title: "Gym",
      description: "A gym (the tenant) as one of its active staff sees it.",
      type: :object,
      additionalProperties: false,
      required: @properties |> Map.keys() |> Enum.sort(),
      properties: @properties
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymResponse do
  @moduledoc "OpenAPI schema: one gym."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.Gym

  OpenApiSpex.schema(
    %{
      title: "GymResponse",
      type: :object,
      additionalProperties: false,
      required: [:gym],
      properties: %{gym: Gym}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSummary do
  @moduledoc "OpenAPI schema: a gym in the viewer's list."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymFields

  @properties GymFields.gym()

  OpenApiSpex.schema(
    %{
      title: "GymSummary",
      description: "A gym where the viewer holds an active staff membership.",
      type: :object,
      additionalProperties: false,
      required: @properties |> Map.keys() |> Enum.sort(),
      properties: @properties
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymList do
  @moduledoc "OpenAPI schema: one page of the viewer's gyms."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymSummary}

  OpenApiSpex.schema(
    %{
      title: "GymList",
      type: :object,
      additionalProperties: false,
      required: [:gyms, :next_cursor],
      properties: %{
        gyms: %Schema{
          type: :array,
          items: GymSummary,
          description: "Newest membership first. Empty when the viewer works at no gym."
        },
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSetupFields do
  @moduledoc "Shared OpenAPI definitions of gym setup (SF-85)."

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.Gym

  @doc "The optional profile and branding fields, writable and readable."
  def optional do
    %{
      phone: %Schema{
        type: :string,
        nullable: true,
        description:
          "Optional contact phone: digits, spaces, `( ) -`, an optional leading `+`; 5-31 characters.",
        example: "+48 22 000 00 00"
      },
      website: %Schema{
        type: :string,
        nullable: true,
        maxLength: 200,
        description: "Optional `http(s)` address with a host and no credentials.",
        example: "https://simpleboxing.pl"
      },
      tagline: %Schema{
        type: :string,
        nullable: true,
        minLength: 1,
        maxLength: 120,
        description: "Optional one-line tagline (OG3).",
        example: "Boxing for everyone. Fighters welcome."
      },
      accent_color: %Schema{
        type: :string,
        nullable: true,
        enum: Gym.accent_colors() ++ [nil],
        description:
          "Optional accent colour: one of OG3's six contrast-checked swatches, lowercase hex."
      }
    }
  end

  @doc "The optimistic-concurrency token of a write."
  def expected_revision do
    %Schema{
      type: :integer,
      minimum: 1,
      description: """
      Required: the `revision` the client last read (from `getGymSetup` or the previous write). When it is no longer
      current the write changes nothing and answers `409 conflict` (`details.revision: "stale"`).
      """
    }
  end
end

defmodule SimpleFitWeb.Schemas.GymSetup do
  @moduledoc "OpenAPI schema: a gym's setup (SF-85)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymLocation, GymSetupFields}

  @properties GymSetupFields.optional()
              |> Map.merge(%{
                gym_id: %Schema{type: :string, format: :uuid},
                setup_status: Map.fetch!(GymFields.gym(), :setup_status),
                revision: %Schema{
                  type: :integer,
                  minimum: 1,
                  description:
                    "Changes with every setup change; send it back as `expected_revision`."
                },
                name: GymFields.name(),
                gym_type: GymFields.gym_type(),
                primary_location: %{
                  GymLocation.schema()
                  | title: nil,
                    nullable: true,
                    description: "The active primary location, or `null` until setup sets one."
                },
                missing_requirements: %Schema{
                  type: :array,
                  items: %Schema{type: :string, enum: ["name", "gym_type", "primary_location"]},
                  description: """
                  What a draft still needs before `completeGymSetup` succeeds; empty when it can complete, and always
                  empty once completed. Nothing commercial is ever required.
                  """
                },
                viewer: GymFields.viewer()
              })

  OpenApiSpex.schema(
    %{
      title: "GymSetup",
      description: "A gym's setup as one of its active staff sees it.",
      type: :object,
      additionalProperties: false,
      required: @properties |> Map.keys() |> Enum.sort(),
      properties: @properties
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSetupResponse do
  @moduledoc "OpenAPI schema: one gym setup."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymSetup

  OpenApiSpex.schema(
    %{
      title: "GymSetupResponse",
      type: :object,
      additionalProperties: false,
      required: [:setup],
      properties: %{setup: GymSetup}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymSetupUpdateRequest do
  @moduledoc "OpenAPI schema: a partial gym setup update (SF-85)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.{GymFields, GymSetupFields}

  OpenApiSpex.schema(
    %{
      title: "GymSetupUpdateRequest",
      description: """
      `expected_revision` and any subset of the setup fields. An omitted field is unchanged; `null` or a blank
      string clears an optional field; `name` and `gym_type` cannot be cleared. Read-only fields (`setup_status`,
      `revision`, owners, ids) are rejected. Only `expected_revision` (or identical values) changes nothing.
      """,
      type: :object,
      additionalProperties: false,
      required: [:expected_revision],
      properties:
        Map.merge(GymSetupFields.optional(), %{
          name: GymFields.name(),
          gym_type: GymFields.gym_type(),
          expected_revision: GymSetupFields.expected_revision()
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymPrimaryLocationRequest do
  @moduledoc "OpenAPI schema: the primary location of a gym (SF-85, OG2)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymSetupFields

  OpenApiSpex.schema(
    %{
      title: "GymPrimaryLocationRequest",
      description: """
      The whole primary address (address only: no map, geocoding or tracking). Replaces every field; an omitted
      optional field is cleared. `name` defaults to the city.
      """,
      type: :object,
      additionalProperties: false,
      required: [:address_line, :city, :country_code, :expected_revision],
      properties: %{
        country_code: %Schema{
          type: :string,
          pattern: "^[A-Za-z]{2}$",
          description: "ISO 3166-1 alpha-2."
        },
        city: %Schema{type: :string, minLength: 1, maxLength: 80},
        address_line: %Schema{type: :string, minLength: 1, maxLength: 200},
        entrance_note: %Schema{type: :string, nullable: true, maxLength: 200},
        name: %Schema{type: :string, nullable: true, maxLength: 80},
        expected_revision: GymSetupFields.expected_revision()
      }
    },
    struct?: false
  )
end
