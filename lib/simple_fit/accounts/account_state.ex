defmodule SimpleFit.Accounts.AccountState do
  @moduledoc """
  A user's account state for operator administration (SF-122): `active` or
  `suspended`, with a trigger-maintained `revision`. A user without a row is active
  at revision 1; the row is created the first time an operator acts on the account.
  """

  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "user_account_states" do
    field :status, Ecto.Enum, values: [:active, :suspended]
    field :revision, :integer, read_after_writes: true
    timestamps()
  end
end

defmodule SimpleFit.Accounts.Restriction do
  @moduledoc """
  One suspension of a user account (SF-122): who started it and why, and when and
  why it was lifted. Never deleted; lifted at most once (database trigger).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "user_restrictions" do
    field :user_id, :binary_id
    field :kind, Ecto.Enum, values: [:suspension]
    field :reason_code, :string
    field :started_at, :utc_datetime_usec
    field :started_by_operator_id, :binary_id
    field :lifted_at, :utc_datetime_usec
    field :lift_reason_code, :string
    field :lifted_by_operator_id, :binary_id
  end
end
