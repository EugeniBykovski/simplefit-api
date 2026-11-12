defmodule SimpleFit.Operators.FlagTarget do
  @moduledoc """
  Runtime flags as admin action targets (SF-128, the SF-111 framework): `id` is the
  flag's row id, `revision` its revision (raised by a trigger on every change), and
  the status `active` or `suspended`. No operator is a party to a flag.
  """

  @behaviour SimpleFit.Operators.ActionTarget

  alias SimpleFit.Configuration
  alias SimpleFit.Configuration.RuntimeFlag

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          key: String.t(),
          revision: pos_integer(),
          status: :active | :suspended,
          flag: RuntimeFlag.t()
        }
  defstruct [:id, :key, :revision, :status, :flag]

  @impl true
  def fetch(id), do: id |> Configuration.fetch_flag() |> from_flag()

  @impl true
  def lock!(id), do: id |> Configuration.lock_flag!() |> from_flag()

  @impl true
  def party?(%__MODULE__{}, _actor), do: false

  @impl true
  def status(%__MODULE__{status: status}), do: Atom.to_string(status)

  @impl true
  def project(%__MODULE__{id: id}), do: Configuration.flag(id)

  defp from_flag(nil), do: nil

  defp from_flag(%RuntimeFlag{} = flag),
    do: %__MODULE__{
      id: flag.id,
      key: flag.key,
      revision: flag.revision,
      status: if(flag.suspended, do: :suspended, else: :active),
      flag: flag
    }
end
