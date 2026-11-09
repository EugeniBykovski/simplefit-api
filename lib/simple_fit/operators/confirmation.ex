defmodule SimpleFit.Operators.Confirmation do
  @moduledoc """
  A one-time confirmation of an admin action (SF-111), issued by its preview. Only
  the token's SHA-256 is stored. It is bound to the operator, the session, the
  action, the target, a digest of the canonical parameters and the expected
  revision, and expires after `SimpleFit.Operators.Policy.confirmation_ttl/0`. A
  trigger lets it be consumed once and changed in no other way.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "operator_action_confirmations" do
    field :token_sha256, :binary
    field :operator_id, :binary_id
    field :session_id, :binary_id
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :params_sha256, :binary
    field :expected_revision, :integer
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end
end
