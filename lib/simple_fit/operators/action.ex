defmodule SimpleFit.Operators.Action do
  @moduledoc """
  The declaration of one admin action (SF-111, ADR 0029). Only declared actions run,
  and only through `SimpleFit.Operators.Actions`: there is no generic execute, no
  table, query, module or function name from a request, and no field patch.

  * `id` - the stable action identifier, e.g. `"operator.suspend"`.
  * `permission`, `assurance` - the capability it needs and the key check
    (`:fresh_key` for every write); the stronger of this and the permission's own
    assurance applies.
  * `target_type` - what the path names; resolved by the action's context, never
    from the body.
  * `reasons` - the reason codes this action accepts. No free text.
  * `params`, `validate` - the action's own input (types and checks), beside the
    common `reason_code`, `expected_revision`, `operation_id` and
    `confirmation_token`.
  * `confirmation` - `:required`: execution needs a one-time confirmation issued by
    a preview of exactly this request; `:none`: a preview is optional.
  * `event` - the audit action of an allowed execution.
  * `plan` - `(actor, target, params) -> {:ok, plan} | {:error, {:conflict, map}}`,
    side-effect free: the current and proposed state and the impact. Previews show
    it; execution computes it again under the locks.
  * `apply` - `(actor, target, params, now, plan) -> any`, inside the transaction;
    rolls back on failure. Domain logic only, no audit (the pipeline writes it).
  """

  @enforce_keys [
    :id,
    :permission,
    :target_type,
    :reasons,
    :confirmation,
    :event,
    :plan,
    :apply
  ]
  defstruct [
    :id,
    :permission,
    :target_type,
    :reasons,
    :confirmation,
    :event,
    :plan,
    :apply,
    assurance: :fresh_key,
    params: %{},
    validate: &Function.identity/1
  ]

  @type plan :: %{
          required(:from_state) => String.t(),
          required(:to_state) => String.t(),
          required(:impact) => [String.t()],
          optional(:permission) => String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          permission: String.t(),
          assurance: :key | :fresh_key,
          target_type: String.t(),
          reasons: [String.t()],
          params: %{atom() => atom()},
          validate: (Ecto.Changeset.t() -> Ecto.Changeset.t()),
          confirmation: :required | :none,
          event: String.t(),
          plan: (struct(), struct(), map() -> {:ok, plan()} | {:error, {:conflict, map()}}),
          apply: (struct(), struct(), map(), DateTime.t(), plan() -> term())
        }
end
