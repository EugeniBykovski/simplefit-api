defmodule SimpleFit.Operators.ActionTarget do
  @moduledoc """
  What an admin action acts on (SF-111, generalized in SF-114, ADR 0032): how the
  pipeline resolves, locks, projects and checks a target. Two kinds exist: platform
  operators (`SimpleFit.Operators.OperatorTarget`) and sponsor applications
  (`SimpleFit.Sponsors.ReviewTarget`). A target has an `id` and a `revision` that a
  trigger maintains.
  """

  @doc "The target, read without a lock, or `nil`."
  @callback fetch(Ecto.UUID.t()) :: struct() | nil

  @doc "Inside the pipeline's transaction: the target locked `FOR UPDATE`, or `nil`."
  @callback lock!(Ecto.UUID.t()) :: struct() | nil

  @doc "Whether the acting operator is a party to the target (self-action, conflict of interest)."
  @callback party?(target :: struct(), actor :: struct()) :: boolean()

  @doc "The target's status, for previews."
  @callback status(struct()) :: String.t()

  @doc "The answer of an executed action."
  @callback project(struct()) :: map()
end
