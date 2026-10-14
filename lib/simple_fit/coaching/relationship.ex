defmodule SimpleFit.Coaching.Relationship do
  @moduledoc """
  One explicitly accepted Coach–Fighter coaching relationship (ADR 0021;
  SF-49 §6).

  It connects a completed coach profile to a completed fighter profile of
  another user, is created `:active` only by a fighter's acceptance
  (`SimpleFit.Coaching.Activation`) and ends once (`:ended`, terminal). It
  records the disclosure version the fighter accepted, which bounds what the
  coach may see. A pending invitation is never a relationship, and nothing
  here refers to a gym. The database enforces the lifecycle, the one active
  relationship per pair, completed profiles and the no-self-coaching rule.

  Rows are written only by `SimpleFit.Coaching`; responses are built from
  explicit projections, never from this struct.
  """

  use Ecto.Schema

  alias SimpleFit.Coaches.CoachProfile
  alias SimpleFit.Fighters.FighterProfile

  @type status :: :active | :ended
  @type party :: :coach | :fighter

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          coach_profile_id: Ecto.UUID.t() | nil,
          fighter_profile_id: Ecto.UUID.t() | nil,
          status: status() | nil,
          disclosure_version: String.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          ended_by: party() | nil,
          fighter_display_name_at_end: String.t() | nil,
          coach_display_name_at_end: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  # The name snapshots are personal data: redacted from inspect output.
  schema "coach_fighter_relationships" do
    belongs_to :coach_profile, CoachProfile
    belongs_to :fighter_profile, FighterProfile

    field :status, Ecto.Enum, values: [:active, :ended]
    field :disclosure_version, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :ended_by, Ecto.Enum, values: [:coach, :fighter]
    field :fighter_display_name_at_end, :string, redact: true
    field :coach_display_name_at_end, :string, redact: true

    timestamps()
  end
end
