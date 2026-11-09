defmodule SimpleFit.Operators.Ceremony do
  @moduledoc "A consumed signed bootstrap or recovery statement. Append-only."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "operator_ceremonies" do
    field :purpose, Ecto.Enum, values: [:bootstrap, :recovery]
    field :key_id, :string
    field :environment, :string
    field :statement_sha256, :binary
    field :target_user_id, :binary_id
    field :operator_id, :binary_id
    field :consumed_at, :utc_datetime_usec
  end
end
