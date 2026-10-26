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
