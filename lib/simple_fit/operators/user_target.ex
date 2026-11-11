defmodule SimpleFit.Operators.UserTarget do
  @moduledoc """
  User accounts as admin action targets (SF-122, the SF-111 framework). The target is
  the account's state (`SimpleFit.Accounts.AccountState`): its `id` is the user id
  and its `revision` the state's. An operator is a party to their own account and
  can't act on it (no self-suspension, no signing oneself out).
  """

  @behaviour SimpleFit.Operators.ActionTarget

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.AccountState

  @type t :: %__MODULE__{id: Ecto.UUID.t(), revision: pos_integer(), status: atom()}
  defstruct [:id, :revision, :status]

  @impl true
  def fetch(id) do
    if Accounts.admin_view(id), do: from_state(Accounts.account_state(id))
  end

  @impl true
  def lock!(id) do
    case Accounts.lock_account!(id) do
      nil -> nil
      %AccountState{} = state -> from_state(state)
    end
  end

  @impl true
  def party?(%__MODULE__{id: id}, %{user_id: id}), do: true
  def party?(%__MODULE__{}, _actor), do: false

  @impl true
  def status(%__MODULE__{status: status}), do: Atom.to_string(status)

  @impl true
  def project(%__MODULE__{} = target),
    do: %{id: target.id, status: Atom.to_string(target.status), revision: target.revision}

  defp from_state(%AccountState{user_id: id, status: status, revision: revision}),
    do: %__MODULE__{id: id, status: status, revision: revision}
end
