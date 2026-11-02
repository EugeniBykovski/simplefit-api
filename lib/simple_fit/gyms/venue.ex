defmodule SimpleFit.Gyms.Venue do
  @moduledoc """
  A bookable training area of a gym (SF-97): a room, a ring, a hall or a
  bag area at one of the gym's own locations. Every class takes place in
  exactly one venue, and venues are exclusive: two scheduled classes never
  overlap in one (a database exclusion constraint). Its IANA `time_zone` is
  where its classes' wall-clock times are read; it never changes. The
  optional `capacity` caps every class held there. An `:inactive` venue
  takes no new classes and never becomes active again; nothing is deleted.
  """

  use Ecto.Schema

  @type status :: :active | :inactive

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          gym_location_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          capacity: pos_integer() | nil,
          time_zone: String.t() | nil,
          status: status() | nil,
          deactivated_at: DateTime.t() | nil,
          revision: pos_integer() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_venues" do
    field :gym_id, :binary_id
    field :gym_location_id, :binary_id
    field :name, :string
    field :description, :string
    field :capacity, :integer
    field :time_zone, :string
    field :status, Ecto.Enum, values: [:active, :inactive], default: :active
    field :deactivated_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    field :client_request_id, :binary_id
    field :created_by_user_id, :binary_id

    timestamps()
  end
end
