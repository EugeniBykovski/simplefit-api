defmodule SimpleFit.Operators.OperatorTarget do
  @moduledoc "Platform operators as admin action targets (SF-111). Never the actor itself."

  @behaviour SimpleFit.Operators.ActionTarget

  import Ecto.Query, only: [from: 2]
  import SimpleFit.Operators.Authority, only: [summary: 1]

  alias SimpleFit.Operators.Operator
  alias SimpleFit.Repo

  @impl true
  def fetch(id), do: Repo.get(Operator, id)

  @impl true
  def lock!(id), do: Repo.one(from(o in Operator, where: o.id == ^id, lock: "FOR UPDATE"))

  @impl true
  def party?(%Operator{id: id}, %Operator{id: id}), do: true
  def party?(_target, _actor), do: false

  @impl true
  def status(%Operator{status: status}), do: Atom.to_string(status)

  @impl true
  def project(%Operator{} = operator), do: summary(operator)
end
