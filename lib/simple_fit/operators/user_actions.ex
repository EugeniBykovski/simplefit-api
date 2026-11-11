defmodule SimpleFit.Operators.UserActions do
  @moduledoc """
  Operator actions on user accounts (SF-122), declared for the SF-111 framework:
  preview, one-time confirmation, expected revision, operation id, reason code and
  audit in one transaction. The Accounts context does the work.

  | Action | Permission | Effect |
  | --- | --- | --- |
  | `user.suspend` | `users.restrict` | `active` -> `suspended`; every session revoked |
  | `user.lift_suspension` | `users.restrict` | `suspended` -> `active`; sessions stay revoked |
  | `user.sign_out_everywhere` | `users.sessions.revoke` | every active session revoked |

  All three need a fresh key check and a confirmation. They're refused against the
  operator's own account (`target: "self"`) and against any account that is a
  platform operator (`target: "operator"`): operators are suspended or revoked
  through operator administration, which keeps its own safeguards (last manager,
  recovery). That check runs under the user row lock, which a concurrent operator
  provisioning for the same user also needs, so the two can't interleave.

  Reason codes are proposed operational defaults (as SF-111's), not approved policy.
  """

  alias SimpleFit.Accounts
  alias SimpleFit.Operators.{Action, Authority, UserTarget}

  @suspend_reasons ~w(abuse_report account_compromise fraud legal_request terms_violation)
  @lift_reasons ~w(appeal_upheld issue_resolved suspended_in_error)
  @sign_out_reasons ~w(account_compromise user_request security_review)

  @doc "Reason codes, per action."
  @spec reasons() :: %{String.t() => [String.t()]}
  def reasons,
    do: %{
      "user.suspend" => @suspend_reasons,
      "user.lift_suspension" => @lift_reasons,
      "user.sign_out_everywhere" => @sign_out_reasons
    }

  @doc "Every user account action."
  @spec definitions() :: [Action.t()]
  def definitions do
    [
      %Action{
        id: "user.suspend",
        permission: "users.restrict",
        target_type: "user",
        target: UserTarget,
        reasons: @suspend_reasons,
        confirmation: :required,
        event: "user.suspended",
        plan: fn _actor, target, _attrs -> plan(target, :active, :suspended) end,
        apply: fn actor, target, attrs, now, _plan ->
          _revoked = Accounts.suspend_account!(target.id, actor.id, attrs.reason_code, now)
          target
        end
      },
      %Action{
        id: "user.lift_suspension",
        permission: "users.restrict",
        target_type: "user",
        target: UserTarget,
        reasons: @lift_reasons,
        confirmation: :required,
        event: "user.suspension_lifted",
        plan: fn _actor, target, _attrs -> plan(target, :suspended, :active) end,
        apply: fn actor, target, attrs, now, _plan ->
          :ok = Accounts.lift_account_suspension!(target.id, actor.id, attrs.reason_code, now)
          target
        end
      },
      %Action{
        id: "user.sign_out_everywhere",
        permission: "users.sessions.revoke",
        target_type: "user",
        target: UserTarget,
        reasons: @sign_out_reasons,
        confirmation: :required,
        event: "user.signed_out_everywhere",
        plan: fn _actor, target, _attrs -> plan_sign_out(target) end,
        apply: fn _actor, target, _attrs, now, _plan ->
          _revoked = Accounts.sign_out_everywhere!(target.id, now)
          target
        end
      }
    ]
  end

  defp plan(%UserTarget{status: from} = target, from, to) do
    with :ok <- not_operator(target) do
      {:ok,
       %{
         from_state: Atom.to_string(from),
         to_state: Atom.to_string(to),
         impact:
           if(to == :suspended,
             do: [
               "signed_out_everywhere",
               "sign_in_refused",
               "data_kept",
               "memberships_unchanged"
             ],
             else: ["sign_in_allowed", "sessions_stay_revoked"]
           )
       }}
    end
  end

  defp plan(%UserTarget{status: status}, _from, _to),
    do: {:error, {:conflict, %{status: Atom.to_string(status)}}}

  defp plan_sign_out(%UserTarget{status: status} = target) do
    with :ok <- not_operator(target) do
      state = Atom.to_string(status)

      {:ok,
       %{from_state: state, to_state: state, impact: ["signed_out_everywhere", "sign_in_allowed"]}}
    end
  end

  # A platform operator's account is administered through operator administration.
  defp not_operator(%UserTarget{id: id}) do
    if Authority.usable_operator(id), do: {:error, {:conflict, %{target: "operator"}}}, else: :ok
  end
end
