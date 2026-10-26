defmodule SimpleFit.Gyms.Gym do
  @moduledoc """
  A gym: the tenant root of everything gym-scoped (ADR 0026, D-G01).

  A gym is created as a `:draft` together with its owner's staff membership
  (`SimpleFit.Gyms.StaffMembership`) and becomes `:completed` only through
  the setup checks of SF-85; completion is final (the database rejects a
  return to draft). Ownership is not stored here: the gym's single active
  `owner` membership is the only source of truth (D-G04). There is no
  publication, plan, payment or verification state (D-G09–D-G11 are
  deferred).

  Rows are written only by `SimpleFit.Gyms`; responses are built from
  explicit projections, never from this struct.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Gyms.{GymLocation, StaffMembership}

  @type gym_type ::
          :boxing_gym
          | :boxing_club
          | :amateur_club
          | :professional_team
          | :combat_sports_gym
          | :fitness_boxing_studio

  @type setup_status :: :draft | :completed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          gym_type: gym_type() | nil,
          setup_status: setup_status() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          locations: [GymLocation.t()] | Ecto.Association.NotLoaded.t(),
          staff_memberships: [StaffMembership.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # OG1's six single-select labels, in design order (D-G13).
  @gym_types [
    :boxing_gym,
    :boxing_club,
    :amateur_club,
    :professional_team,
    :combat_sports_gym,
    :fitness_boxing_studio
  ]

  @control ~r/[\p{Cc}\p{Cf}]/u

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gyms" do
    field :name, :string
    field :gym_type, Ecto.Enum, values: @gym_types
    field :setup_status, Ecto.Enum, values: [:draft, :completed]
    field :created_by_user_id, :binary_id
    field :client_request_id, :binary_id

    has_many :locations, GymLocation
    has_many :staff_memberships, StaffMembership

    timestamps()
  end

  @doc "The gym types (D-G13), in design order."
  @spec gym_types() :: [gym_type()]
  def gym_types, do: @gym_types

  @doc """
  A new draft gym for `created_by_user_id` from the creation fields (`name`,
  `gym_type`). The name is trimmed and must be 1–80 printable characters.
  """
  @spec create_changeset(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: Ecto.Changeset.t()
  def create_changeset(created_by_user_id, client_request_id, attrs) do
    %__MODULE__{
      created_by_user_id: created_by_user_id,
      client_request_id: client_request_id,
      setup_status: :draft
    }
    |> cast(attrs, [:name, :gym_type])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :gym_type])
    |> validate_length(:name, min: 1, max: 80, count: :codepoints)
    |> validate_change(:name, fn :name, name ->
      if Regex.match?(@control, name),
        do: [name: {"must not contain control characters", [validation: :format]}],
        else: []
    end)
    |> check_constraint(:name, name: :name_length)
    |> check_constraint(:gym_type, name: :gym_type_values)
  end
end
