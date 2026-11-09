defmodule SimpleFit.Operators.StepUp do
  @moduledoc """
  Proof that an operator verified a security key in one session. Valid only for
  that session, until `expires_at`, and only while not revoked.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "operator_step_ups" do
    field :operator_id, :binary_id
    field :session_id, :binary_id
    field :credential_id, :binary_id
    field :verified_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end
end
