defmodule SimpleFit.Gyms.ClassSeries do
  @moduledoc """
  A bounded weekly rule of a gym class (SF-97): ISO `weekdays` (1 = Monday),
  a wall-clock `local_start_time` in the venue's `time_zone`, a duration,
  and the first and last dates (at most a year apart). It is fully
  materialized into occurrences, one per date (`series_local_date`), so
  every class it schedules is checked against the venue and the instructor
  when it is written. Dates whose local start time does not exist (spring
  gap) or exists twice (autumn repeated hour) are skipped and reported.
  A `:cancelled` series is final.
  """

  use Ecto.Schema

  @type status :: :active | :cancelled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          template_id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          instructor_staff_membership_id: Ecto.UUID.t() | nil,
          time_zone: String.t() | nil,
          weekdays: [1..7] | nil,
          local_start_time: Time.t() | nil,
          duration_minutes: pos_integer() | nil,
          capacity: pos_integer() | nil,
          starts_on: Date.t() | nil,
          ends_on: Date.t() | nil,
          status: status() | nil,
          cancelled_at: DateTime.t() | nil,
          revision: pos_integer() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_class_series" do
    field :gym_id, :binary_id
    field :template_id, :binary_id
    field :venue_id, :binary_id
    field :instructor_staff_membership_id, :binary_id
    field :time_zone, :string
    field :weekdays, {:array, :integer}
    field :local_start_time, :time
    field :duration_minutes, :integer
    field :capacity, :integer
    field :starts_on, :date
    field :ends_on, :date
    field :status, Ecto.Enum, values: [:active, :cancelled], default: :active
    field :cancelled_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    field :client_request_id, :binary_id
    field :created_by_user_id, :binary_id

    timestamps()
  end
end
