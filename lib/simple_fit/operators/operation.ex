defmodule SimpleFit.Operators.Operation do
  @moduledoc """
  A client-supplied operation id, recorded once, so a repeated request changes
  nothing. Append-only.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "operator_operations" do
    field :actor_operator_id, :binary_id
    field :action, :string
    field :target_id, :binary_id

    timestamps()
  end
end
