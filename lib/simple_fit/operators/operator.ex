defmodule SimpleFit.Operators.Operator do
  @moduledoc """
  A platform operator (SF-110, ADR 0028): a separately provisioned authority bound
  to one global user. It isn't a role on the user, and holding one grants nothing
  by itself: every request is authorized by `SimpleFit.Operators.Authority`.

  `pending_enrollment` operators can only register security keys. `revoked` is
  terminal (a returning person gets a new row). Transitions are enforced by a
  trigger; rows are never deleted.
  """

  use Ecto.Schema

  @type status :: :pending_enrollment | :active | :suspended | :revoked
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "platform_operators" do
    field :user_id, :binary_id
    field :status, Ecto.Enum, values: [:pending_enrollment, :active, :suspended, :revoked]
    field :bootstrap, :boolean, default: false
    field :created_by_operator_id, :binary_id
    field :ceremony_id, :binary_id
    field :enrollment_expires_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec
    field :suspended_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end
end
