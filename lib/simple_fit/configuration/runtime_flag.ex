defmodule SimpleFit.Configuration.RuntimeFlag do
  @moduledoc """
  A runtime suspension of one allowlisted, deployment-enabled feature (SF-128). The
  key list is a database check constraint; `revision` is raised by a trigger on every
  change of `suspended`. Never deleted.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "runtime_flags" do
    field :key, :string
    field :suspended, :boolean, default: false
    field :revision, :integer, read_after_writes: true
    timestamps(type: :utc_datetime_usec)
  end
end
