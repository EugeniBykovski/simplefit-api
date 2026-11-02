defmodule SimpleFit.Gyms.ClassOccurrence do
  @moduledoc """
  An actual dated gym class (SF-97): UTC `starts_at` and `ends_at` (exactly
  `duration_minutes` of elapsed time apart), the `time_zone` it was
  scheduled in, its venue, instructor and capacity. A one-time class has no
  series; a series class keeps its `series_local_date` (its identity in the
  series) even when moved on its own (`rescheduled_at`).

  Statuses: `:scheduled` and `:cancelled`. Cancellation is final, except
  for a class the series rule itself took away (`cancel_reason:
  :series_changed`), which a later rule may bring back. Nothing is inferred
  from the clock: there is no "completed" or attendance here. The
  `instructor_user_id` is set by the database from the instructor's staff
  membership; `instructor_released_at` marks a class whose instructor lost
  their access (it needs a new instructor). Rows are never deleted. Not a
  TrainingSession (ADR 0023) and never a booking.
  """

  use Ecto.Schema

  @type status :: :scheduled | :cancelled
  @type cancel_reason :: :cancelled | :series_changed | :series_cancelled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          template_id: Ecto.UUID.t() | nil,
          series_id: Ecto.UUID.t() | nil,
          series_local_date: Date.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          instructor_staff_membership_id: Ecto.UUID.t() | nil,
          instructor_user_id: Ecto.UUID.t() | nil,
          instructor_released_at: DateTime.t() | nil,
          title: String.t() | nil,
          time_zone: String.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          duration_minutes: pos_integer() | nil,
          capacity: pos_integer() | nil,
          status: status() | nil,
          cancelled_at: DateTime.t() | nil,
          cancel_reason: cancel_reason() | nil,
          cancelled_by_user_id: Ecto.UUID.t() | nil,
          rescheduled_at: DateTime.t() | nil,
          revision: pos_integer() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_class_occurrences" do
    field :gym_id, :binary_id
    field :template_id, :binary_id
    field :series_id, :binary_id
    field :series_local_date, :date
    field :venue_id, :binary_id
    field :instructor_staff_membership_id, :binary_id
    field :instructor_user_id, :binary_id, read_after_writes: true
    field :instructor_released_at, :utc_datetime_usec
    field :title, :string
    field :time_zone, :string
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :duration_minutes, :integer
    field :capacity, :integer
    field :status, Ecto.Enum, values: [:scheduled, :cancelled], default: :scheduled
    field :cancelled_at, :utc_datetime_usec
    field :cancel_reason, Ecto.Enum, values: [:cancelled, :series_changed, :series_cancelled]
    field :cancelled_by_user_id, :binary_id
    field :rescheduled_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    field :client_request_id, :binary_id
    field :created_by_user_id, :binary_id

    timestamps()
  end
end
