defmodule SimpleFit.Operators.ConfigurationActions do
  @moduledoc """
  Operator actions on runtime flags (SF-128, D-SA35), declared for the SF-111
  framework: preview, one-time confirmation bound to the flag, revision and reason,
  operation id, fresh key check and audit in one transaction.

  | Action | Permission | Effect |
  | --- | --- | --- |
  | `config.flag.suspend` | `config.flags.write` | `active` -> `suspended`: the feature is off whatever the deployment says |
  | `config.flag.restore` | `config.flags.write` | `suspended` -> `active`: the deployment decides again |

  Either is the other's rollback: each writes a new revision and history row, and
  neither recalls what the feature already did (sent emails, stored files). Only the
  allowlisted keys have rows, so nothing else can be targeted, and no action enables a
  feature beyond its deployment. No approval step exists: no high-risk switch is
  editable (payments, Stripe mode, coaching and API docs are read-only).

  Reason codes are proposed operational defaults, not approved policy.
  """

  alias SimpleFit.Configuration
  alias SimpleFit.Operators.{Action, FlagTarget}

  @suspend_reasons ~w(incident_response provider_outage abuse_or_spam release_issue planned_maintenance)
  @restore_reasons ~w(incident_resolved provider_recovered abuse_contained release_fixed maintenance_complete suspended_in_error)

  @doc "Reason codes, per action."
  @spec reasons() :: %{String.t() => [String.t()]}
  def reasons,
    do: %{"config.flag.suspend" => @suspend_reasons, "config.flag.restore" => @restore_reasons}

  @doc "Both runtime flag actions."
  @spec definitions() :: [Action.t()]
  def definitions do
    [
      %Action{
        id: "config.flag.suspend",
        permission: "config.flags.write",
        target_type: "runtime_flag",
        target: FlagTarget,
        reasons: @suspend_reasons,
        confirmation: :required,
        event: "config.flag_suspended",
        plan: fn _actor, target, _attrs -> plan(target, :active, :suspended) end,
        apply: fn actor, target, attrs, _now, _plan -> set(target, true, actor, attrs) end
      },
      %Action{
        id: "config.flag.restore",
        permission: "config.flags.write",
        target_type: "runtime_flag",
        target: FlagTarget,
        reasons: @restore_reasons,
        confirmation: :required,
        event: "config.flag_restored",
        plan: fn _actor, target, _attrs -> plan(target, :suspended, :active) end,
        apply: fn actor, target, attrs, _now, _plan -> set(target, false, actor, attrs) end
      }
    ]
  end

  defp plan(%FlagTarget{status: from, flag: flag}, from, to) do
    entry = Configuration.flag_entry(flag)

    deployment =
      if entry.deployment_value == true,
        do: ["deployment_enabled"],
        else: ["deployment_disabled_no_effect"]

    effect = if to == :suspended, do: entry.impact, else: ["deployment_decides"]

    {:ok,
     %{
       from_state: Atom.to_string(from),
       to_state: Atom.to_string(to),
       impact: effect ++ deployment ++ ["effective_next_check_every_instance", "not_retroactive"]
     }}
  end

  defp plan(%FlagTarget{status: status}, _from, _to),
    do: {:error, {:conflict, %{status: Atom.to_string(status)}}}

  defp set(%FlagTarget{} = target, suspended, actor, attrs) do
    flag =
      Configuration.set_suspended!(
        target.flag,
        suspended,
        actor.id,
        attrs.reason_code,
        attrs.operation_id
      )

    %FlagTarget{target | flag: flag, revision: flag.revision}
  end
end
