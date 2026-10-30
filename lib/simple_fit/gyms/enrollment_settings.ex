defmodule SimpleFit.Gyms.EnrollmentSettings do
  @moduledoc """
  A gym's member enrollment settings (D-G08; SF-95): its join code and its
  auto-approval choice. One row per gym, created by the first change; a gym
  without one has no join code and no auto-approval.

  The join code is stored as an HMAC digest (the lookup key) and an
  encrypted copy that the gym's staff can display
  (`SimpleFit.Gyms.MemberSecrets`); no code means joining by code is
  disabled. `auto_approve` is `false` unless an owner or manager explicitly
  enabled it, and even then it never activates a joiner without a completed
  account and a verified sign-in identity.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          gym_id: Ecto.UUID.t() | nil,
          join_code_digest: binary() | nil,
          join_code_sealed: String.t() | nil,
          join_code_rotated_at: DateTime.t() | nil,
          auto_approve: boolean() | nil,
          auto_approve_changed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:gym_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_enrollment_settings" do
    field :join_code_digest, :binary, redact: true
    field :join_code_sealed, :string, redact: true
    field :join_code_rotated_at, :utc_datetime_usec
    field :auto_approve, :boolean, default: false
    field :auto_approve_changed_at, :utc_datetime_usec

    timestamps()
  end
end
