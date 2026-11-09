defmodule SimpleFit.Sponsors.ReviewActions do
  @moduledoc """
  Sponsor application review actions for the SF-111 framework (SF-114, ADR 0032).
  Each needs its own permission and a fresh key check, names the application's
  `expected_revision`, takes a reason code from its list, and can't target the
  operator's own application.

  | Action | Permission | Change |
  | --- | --- | --- |
  | `sponsor_application.claim` | `sponsors.applications.claim` | `submitted` -> `under_review` |
  | `sponsor_application.request_changes` | `sponsors.applications.request_changes` | `under_review` -> `changes_requested`, with the answers to revisit and a message |
  | `sponsor_application.approve` | `sponsors.applications.approve` | `under_review` -> `approved`, with the organization and the applicant's owner membership (SF-116) |
  | `sponsor_application.reject` | `sponsors.applications.reject` | `under_review` -> `rejected` (SF-116) |
  | `sponsor_application.suspend_organization` | `sponsors.restrict` | the approved application's organization `active` -> `suspended` (SF-116) |
  | `sponsor_application.reinstate_organization` | `sponsors.restrict` | that organization `suspended` -> `active` (SF-116) |

  Claim and request changes need no preview confirmation: both are undone by the
  applicant's next submission. The four SF-116 actions can't be undone the same way,
  so each needs a one-time confirmation from a preview of exactly that request. Only
  approval creates anything (the organization and its owner); nothing creates
  anything commercial.
  """

  alias SimpleFit.Accounts
  alias SimpleFit.Operators.Action
  alias SimpleFit.Repo
  alias SimpleFit.Sponsors.{Review, ReviewTarget}

  @doc "Every sponsor review action."
  @spec definitions() :: [Action.t()]
  def definitions do
    [
      %Action{
        id: "sponsor_application.claim",
        permission: "sponsors.applications.claim",
        target_type: "sponsor_application",
        target: ReviewTarget,
        reasons: ~w(review_started),
        confirmation: :none,
        event: "sponsor_application.claimed",
        plan: &plan_claim/3,
        apply: fn actor, target, attrs, _now, _plan -> Review.claim!(target, actor, attrs) end
      },
      %Action{
        id: "sponsor_application.request_changes",
        permission: "sponsors.applications.request_changes",
        target_type: "sponsor_application",
        target: ReviewTarget,
        reasons: Review.change_reasons(),
        params: %{fields: {:array, :string}, message: :string},
        validate: &Review.validate_change_request/1,
        confirmation: :none,
        event: "sponsor_application.changes_requested",
        plan: &plan_request_changes/3,
        apply: fn actor, target, attrs, now, _plan ->
          Review.request_changes!(target, actor, attrs, now)
        end
      },
      %Action{
        id: "sponsor_application.approve",
        permission: "sponsors.applications.approve",
        target_type: "sponsor_application",
        target: ReviewTarget,
        reasons: Review.decision_reasons(:approve),
        confirmation: :required,
        event: "sponsor_application.approved",
        plan: &plan_approve/3,
        apply: fn actor, target, attrs, now, _plan ->
          Review.approve!(target, actor, attrs, now, %{})
        end
      },
      %Action{
        id: "sponsor_application.reject",
        permission: "sponsors.applications.reject",
        target_type: "sponsor_application",
        target: ReviewTarget,
        reasons: Review.decision_reasons(:reject),
        confirmation: :required,
        event: "sponsor_application.rejected",
        plan: &plan_reject/3,
        apply: fn actor, target, attrs, now, _plan ->
          Review.reject!(target, actor, attrs, now)
        end
      },
      %Action{
        id: "sponsor_application.suspend_organization",
        permission: "sponsors.restrict",
        target_type: "sponsor_application",
        target: ReviewTarget,
        reasons: Review.decision_reasons(:suspend),
        confirmation: :required,
        event: "sponsor_application.organization_suspended",
        plan: fn _actor, target, _attrs -> plan_restrict(target, :active, :suspended) end,
        apply: fn actor, target, attrs, _now, _plan ->
          Review.restrict!(target, actor, attrs, :suspended, %{})
        end
      },
      %Action{
        id: "sponsor_application.reinstate_organization",
        permission: "sponsors.restrict",
        target_type: "sponsor_application",
        target: ReviewTarget,
        reasons: Review.decision_reasons(:reinstate),
        confirmation: :required,
        event: "sponsor_application.organization_reinstated",
        plan: fn _actor, target, _attrs -> plan_restrict(target, :suspended, :active) end,
        apply: fn actor, target, attrs, _now, _plan ->
          Review.restrict!(target, actor, attrs, :active, %{})
        end
      }
    ]
  end

  # Approval needs a claimed application, an applicant who can own an organization
  # (completed registration) and no organization already made from it.
  defp plan_approve(_actor, %{status: :under_review} = application, _attrs) do
    cond do
      Review.organization_of(application.id) ->
        {:error, {:conflict, %{organization: "exists"}}}

      not Accounts.registration_complete?(Repo.get!(Accounts.User, application.applicant_user_id)) ->
        {:error, {:conflict, %{applicant: "not_eligible"}}}

      true ->
        {:ok,
         %{
           from_state: "under_review",
           to_state: "approved",
           impact: [
             "organization_created",
             "applicant_becomes_owner",
             "applicant_notified",
             "no_commercial_rights"
           ]
         }}
    end
  end

  defp plan_approve(_actor, %{status: status}, _attrs),
    do: {:error, {:conflict, %{status: Atom.to_string(status)}}}

  defp plan_reject(_actor, %{status: :under_review}, _attrs),
    do:
      {:ok,
       %{
         from_state: "under_review",
         to_state: "rejected",
         impact: ["final_decision", "applicant_notified", "nothing_created"]
       }}

  defp plan_reject(_actor, %{status: status}, _attrs),
    do: {:error, {:conflict, %{status: Atom.to_string(status)}}}

  # The organization of an approved application, in `from`.
  defp plan_restrict(%{status: :approved} = application, from, to) do
    case Review.organization_of(application.id) do
      %{status: ^from} ->
        {:ok,
         %{
           from_state: Atom.to_string(from),
           to_state: Atom.to_string(to),
           impact:
             if(to == :suspended,
               do: ["organization_read_only", "no_entry_destination", "nothing_deleted"],
               else: ["organization_usable_again"]
             )
         }}

      %{status: status} ->
        {:error, {:conflict, %{organization: Atom.to_string(status)}}}

      nil ->
        {:error, {:conflict, %{organization: "none"}}}
    end
  end

  defp plan_restrict(%{status: status}, _from, _to),
    do: {:error, {:conflict, %{status: Atom.to_string(status)}}}

  defp plan_claim(_actor, %{status: :submitted}, _attrs),
    do: {:ok, %{from_state: "submitted", to_state: "under_review", impact: ["review_started"]}}

  defp plan_claim(_actor, %{status: status}, _attrs),
    do: {:error, {:conflict, %{status: Atom.to_string(status)}}}

  defp plan_request_changes(_actor, %{status: :under_review}, _attrs),
    do:
      {:ok,
       %{
         from_state: "under_review",
         to_state: "changes_requested",
         impact: ["applicant_can_edit_requested_answers", "applicant_notified"]
       }}

  defp plan_request_changes(_actor, %{status: status}, _attrs),
    do: {:error, {:conflict, %{status: Atom.to_string(status)}}}
end
