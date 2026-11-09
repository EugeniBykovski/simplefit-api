defmodule SimpleFit.Operators.OperatorActions do
  @moduledoc """
  The operator administration actions (SF-110's writes, declared for the SF-111
  framework, ADR 0029). Internal to `SimpleFit.Operators`.

  | Action | Permission | Confirmation | Change |
  | --- | --- | --- | --- |
  | `operator.permission.grant` | `operators.manage` | required | adds one permission |
  | `operator.permission.revoke` | `operators.manage` | none | removes one permission |
  | `operator.suspend` | `operators.manage` | required | `active` → `suspended`, ends key checks |
  | `operator.reinstate` | `operators.manage` | required | `suspended` → `active` (or `pending_enrollment` without enough keys) |
  | `operator.revoke` | `operators.manage` | required | → `revoked`, final: permissions, keys and key checks end |

  Removing a permission only narrows access, so it needs no confirmation; every
  other action widens access or ends it, so it does. All need a fresh key check, a
  reason code from the action's own list and the expected revision, and none can
  target the actor.

  The reason codes are operational categories for operator access management,
  proposed by SF-111 (ADR 0029). They aren't a legal or compliance taxonomy.
  """

  import Ecto.Changeset, only: [change: 2, validate_inclusion: 3]
  import Ecto.Query, only: [from: 2]
  import SimpleFit.Operators.Authority, only: [granted?: 2, active_credential_count: 1]

  alias SimpleFit.Operators.{Action, Credential, Grant, Operator, Policy, StepUp}
  alias SimpleFit.Repo

  @doc "Every operator action."
  @spec definitions() :: [Action.t()]
  def definitions do
    [
      %Action{
        id: "operator.permission.grant",
        permission: "operators.manage",
        target_type: "operator",
        reasons: ~w(access_request_approved role_change administrative_correction),
        params: %{permission: :string},
        validate: &validate_inclusion(&1, :permission, Policy.permissions()),
        confirmation: :required,
        event: "operator.permission_granted",
        plan: &plan_grant/3,
        apply: &apply_grant/5
      },
      %Action{
        id: "operator.permission.revoke",
        permission: "operators.manage",
        target_type: "operator",
        reasons:
          ~w(role_change least_privilege_review security_concern administrative_correction),
        params: %{permission: :string},
        confirmation: :none,
        event: "operator.permission_revoked",
        plan: &plan_revoke_grant/3,
        apply: &apply_revoke_grant/5
      },
      %Action{
        id: "operator.suspend",
        permission: "operators.manage",
        target_type: "operator",
        reasons:
          ~w(security_concern suspected_compromise policy_violation leave_of_absence administrative_correction),
        confirmation: :required,
        event: "operator.suspended",
        plan: &plan_suspend/3,
        apply: &apply_suspend/5
      },
      %Action{
        id: "operator.reinstate",
        permission: "operators.manage",
        target_type: "operator",
        reasons: ~w(security_review_cleared returned_from_leave administrative_correction),
        confirmation: :required,
        event: "operator.reinstated",
        plan: &plan_reinstate/3,
        apply: &apply_reinstate/5
      },
      %Action{
        id: "operator.revoke",
        permission: "operators.manage",
        target_type: "operator",
        reasons:
          ~w(left_organization security_concern suspected_compromise policy_violation administrative_correction),
        confirmation: :required,
        event: "operator.revoked",
        plan: &plan_revoke/3,
        apply: &apply_revoke/5
      }
    ]
  end

  ## Plans (side-effect free)

  defp plan_grant(_actor, %Operator{status: :revoked}, _params),
    do: {:error, {:conflict, %{operator: "revoked"}}}

  defp plan_grant(_actor, target, %{permission: permission}) do
    if granted?(target.id, permission) do
      {:error, {:conflict, %{permission: "already_granted"}}}
    else
      {:ok,
       %{
         from_state: "absent",
         to_state: "granted",
         permission: permission,
         impact: [
           "permission_granted" | if(target.status == :active, do: ["effective_now"], else: [])
         ]
       }}
    end
  end

  defp plan_revoke_grant(_actor, target, %{permission: permission}) do
    if granted?(target.id, permission) do
      {:ok,
       %{
         from_state: "granted",
         to_state: "revoked",
         permission: permission,
         impact: ["permission_revoked"]
       }}
    else
      {:error, {:conflict, %{permission: "not_granted"}}}
    end
  end

  defp plan_suspend(_actor, %Operator{status: :active}, _params),
    do:
      {:ok,
       %{
         from_state: "active",
         to_state: "suspended",
         impact: ["access_blocked", "key_checks_ended"]
       }}

  defp plan_suspend(_actor, _target, _params), do: {:error, {:conflict, %{status: "not_active"}}}

  defp plan_reinstate(_actor, %Operator{status: :suspended} = target, _params) do
    if active_credential_count(target.id) >= Policy.required_authenticators() do
      {:ok, %{from_state: "suspended", to_state: "active", impact: ["access_restored"]}}
    else
      {:ok,
       %{
         from_state: "suspended",
         to_state: "pending_enrollment",
         impact: ["security_keys_required"]
       }}
    end
  end

  defp plan_reinstate(_actor, _target, _params),
    do: {:error, {:conflict, %{status: "not_suspended"}}}

  defp plan_revoke(_actor, %Operator{status: :revoked}, _params),
    do: {:error, {:conflict, %{status: "revoked"}}}

  defp plan_revoke(_actor, target, _params),
    do:
      {:ok,
       %{
         from_state: Atom.to_string(target.status),
         to_state: "revoked",
         impact: [
           "access_blocked",
           "permissions_revoked",
           "security_keys_revoked",
           "key_checks_ended",
           "irreversible"
         ]
       }}

  ## Mutations (inside the pipeline's transaction)

  defp apply_grant(actor, target, %{permission: permission} = params, now, _plan) do
    %Grant{
      operator_id: target.id,
      permission: permission,
      granted_by_operator_id: actor.id,
      reason_code: params.reason_code,
      operation_id: params.operation_id,
      granted_at: now
    }
    |> change(%{})
    |> Ecto.Changeset.unique_constraint([:operator_id, :permission],
      name: :operator_permission_grants_one_active_index
    )
    |> Repo.insert()
    |> case do
      {:ok, grant} -> grant
      {:error, _} -> Repo.rollback({:conflict, %{permission: "already_granted"}})
    end
  end

  defp apply_revoke_grant(actor, target, %{permission: permission} = params, now, _plan) do
    grant =
      Repo.one(
        from(g in Grant,
          where:
            g.operator_id == ^target.id and g.permission == ^permission and is_nil(g.revoked_at),
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback({:conflict, %{permission: "not_granted"}})

    Repo.update!(
      change(grant,
        revoked_at: now,
        revoked_by_operator_id: actor.id,
        revoke_reason_code: params.reason_code
      )
    )
  end

  defp apply_suspend(_actor, target, _params, now, _plan) do
    end_step_ups!(from(s in StepUp, where: s.operator_id == ^target.id))
    Repo.update!(change(target, status: :suspended, suspended_at: now))
  end

  defp apply_reinstate(_actor, target, _params, now, %{to_state: "active"}),
    do: Repo.update!(change(target, status: :active, activated_at: target.activated_at || now))

  defp apply_reinstate(_actor, target, _params, now, %{to_state: "pending_enrollment"}) do
    Repo.update!(
      change(target,
        status: :pending_enrollment,
        enrollment_expires_at: DateTime.add(now, Policy.enrollment_window())
      )
    )
  end

  defp apply_revoke(actor, target, _params, now, _plan) do
    end_step_ups!(from(s in StepUp, where: s.operator_id == ^target.id))

    Repo.update_all(
      from(c in Credential, where: c.operator_id == ^target.id and is_nil(c.revoked_at)),
      set: [revoked_at: now, revoked_reason: "operator_revoked"]
    )

    Repo.update_all(
      from(g in Grant, where: g.operator_id == ^target.id and is_nil(g.revoked_at)),
      set: [
        revoked_at: now,
        revoked_by_operator_id: actor.id,
        revoke_reason_code: "operator_revoked"
      ]
    )

    Repo.update!(change(target, status: :revoked, revoked_at: now))
  end

  defp end_step_ups!(query) do
    Repo.update_all(from(s in query, where: is_nil(s.revoked_at)),
      set: [revoked_at: DateTime.utc_now()]
    )
  end
end
