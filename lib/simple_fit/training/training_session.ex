defmodule SimpleFit.Training.TrainingSession do
  @moduledoc """
  One planned training a coach assigns to one fighter within one active
  Coach–Fighter relationship (ADR 0023; SF-49 §8).

  It is created `:planned` and ends once: `:completed` (the fighter's
  confirmation, SF-63) or `:cancelled` (by the coach, or by the system when
  the relationship ends). Both are terminal. The coach and the fighter are
  always exactly the relationship's (a composite foreign key); there is no
  gym, group, metric or free-form plan. The database enforces the lifecycle,
  the transitions, the relationship being active at creation and the zone.

  Rows are written only by `SimpleFit.Training`; responses are built from
  explicit projections, never from this struct.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type status :: :planned | :completed | :cancelled
  @type training_type :: :technical | :sparring | :pads | :strength_conditioning | :roadwork

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          coach_fighter_relationship_id: Ecto.UUID.t() | nil,
          coach_profile_id: Ecto.UUID.t() | nil,
          fighter_profile_id: Ecto.UUID.t() | nil,
          client_request_id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          training_type: training_type() | nil,
          starts_at: DateTime.t() | nil,
          time_zone: String.t() | nil,
          duration_minutes: pos_integer() | nil,
          notes: String.t() | nil,
          status: status() | nil,
          completed_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          cancelled_by: :coach | :system | nil,
          cancel_reason: :relationship_ended | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @training_types [:technical, :sparring, :pads, :strength_conditioning, :roadwork]

  # The plan a coach writes; everything else is set by the backend.
  @plan_fields [:title, :training_type, :starts_at, :time_zone, :duration_minutes, :notes]
  @required_plan [:title, :training_type, :starts_at, :time_zone, :duration_minutes]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  # Titles and notes are the coach's words about a person's training:
  # redacted from inspect output.
  schema "training_sessions" do
    field :coach_fighter_relationship_id, :binary_id
    field :coach_profile_id, :binary_id
    field :fighter_profile_id, :binary_id
    field :client_request_id, :binary_id

    field :title, :string, redact: true
    field :training_type, Ecto.Enum, values: @training_types
    field :starts_at, :utc_datetime_usec
    field :time_zone, :string
    field :duration_minutes, :integer
    field :notes, :string, redact: true

    field :status, Ecto.Enum, values: [:planned, :completed, :cancelled]
    field :completed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :cancelled_by, Ecto.Enum, values: [:coach, :system]
    field :cancel_reason, Ecto.Enum, values: [:relationship_ended]

    timestamps()
  end

  @doc "The training types (SF-49 §8.2.1, decision O-5)."
  @spec training_types() :: [training_type()]
  def training_types, do: @training_types

  @doc "The fields a coach may set when creating and change while planned."
  @spec plan_fields() :: [atom()]
  def plan_fields, do: @plan_fields

  @doc """
  The plan of a new session, or changes to a planned one, from the coach's
  `attrs` (string keys; on an update only the keys present change). Owners,
  the request key and the status are set by `SimpleFit.Training`, never taken
  from `attrs`. `notes: null` clears the notes; no other field can be
  cleared.
  """
  @spec plan_changeset(t(), map()) :: Ecto.Changeset.t()
  def plan_changeset(%__MODULE__{} = session, attrs) do
    session
    |> cast(attrs, @plan_fields, empty_values: [])
    |> update_change(:title, &trim/1)
    |> validate_required(@required_plan)
    |> validate_plan()
  end

  # A blank title is a missing one.
  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(value), do: value

  defp validate_plan(changeset) do
    changeset
    |> validate_length(:title, min: 1, max: 80)
    |> validate_number(:duration_minutes, greater_than_or_equal_to: 5, less_than_or_equal_to: 600)
    |> validate_length(:notes, min: 1, max: 2000)
    |> validate_length(:time_zone, min: 1, max: 64)
  end
end
