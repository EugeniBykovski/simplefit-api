defmodule SimpleFit.Gyms.GymLocation do
  @moduledoc """
  An address-only place of a gym (ADR 0026, D-G02): no geocoding, map or
  tracking. A gym has at most one non-archived primary location (partial
  unique index). Locations are created and edited by the setup and settings
  tickets (SF-85); SF-83 only defines the entity and reads it.
  """

  use Ecto.Schema

  alias SimpleFit.Gyms.Gym

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          country_code: String.t() | nil,
          city: String.t() | nil,
          address_line: String.t() | nil,
          entrance_note: String.t() | nil,
          is_primary: boolean() | nil,
          archived_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_locations" do
    belongs_to :gym, Gym
    field :name, :string
    field :country_code, :string
    field :city, :string
    field :address_line, :string
    field :entrance_note, :string
    field :is_primary, :boolean
    field :archived_at, :utc_datetime_usec

    timestamps()
  end
end
