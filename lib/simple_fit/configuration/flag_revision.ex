defmodule SimpleFit.Configuration.FlagRevision do
  @moduledoc """
  One change of a runtime flag (SF-128): `suspend` or `restore`, its previous and new
  state, the operator, reason and operation id. Append-only (a trigger refuses
  updates and deletes).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "runtime_flag_revisions" do
    field :flag_id, :binary_id
    field :revision, :integer
    field :change, Ecto.Enum, values: [:suspend, :restore]
    field :suspended, :boolean
    field :previous_suspended, :boolean
    field :operator_id, :binary_id
    field :reason_code, :string
    field :operation_id, :binary_id
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
