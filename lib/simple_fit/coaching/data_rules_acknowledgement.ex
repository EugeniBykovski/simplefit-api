defmodule SimpleFit.Coaching.DataRulesAcknowledgement do
  @moduledoc """
  A coach's acknowledgement of one version of the coach data rules (SF-49
  §7.4): separate from account consents (ADR 0016) and from the coach
  profile. Append-only, one row per version.
  """

  use Ecto.Schema

  alias SimpleFit.Coaches.CoachProfile

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          coach_profile_id: Ecto.UUID.t() | nil,
          document_version: String.t() | nil,
          acknowledged_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "coach_data_rules_acknowledgements" do
    belongs_to :coach_profile, CoachProfile
    field :document_version, :string
    field :acknowledged_at, :utc_datetime_usec
  end
end
