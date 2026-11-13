defmodule SimpleFit.Sponsors.ProposalReviewActions do
  @moduledoc """
  Partnership proposal review actions for the SF-111 framework (SF-130, ADR 0034;
  D-SA37). Each needs its own permission and a fresh key check, names the proposal's
  `expected_revision`, takes a reason code from its list, and can't target a proposal
  of an organization the operator belongs to.

  | Action | Permission | Change |
  | --- | --- | --- |
  | `sponsor_proposal.claim` | `sponsors.proposals.claim` | `submitted` -> `under_review` |
  | `sponsor_proposal.request_changes` | `sponsors.proposals.request_changes` | `under_review` -> `changes_requested`, with the answers to revisit and a message |
  | `sponsor_proposal.accept` | `sponsors.proposals.accept` | `under_review` -> `accepted` (follow-up only; creates nothing) |
  | `sponsor_proposal.decline` | `sponsors.proposals.decline` | `under_review` -> `declined` |

  Claim and request changes need no preview confirmation: the organization's next
  submission or withdrawal follows them. Accept and decline are final, so each needs a
  one-time confirmation from a preview of exactly that request. Nothing creates
  anything commercial. Claiming, requesting changes and accepting need the
  organization to be active (a suspended one can't respond or be followed up);
  declining doesn't.
  """

  alias SimpleFit.Operators.Action
  alias SimpleFit.Sponsors.{ProposalReview, ProposalTarget}

  @doc "Every proposal review action."
  @spec definitions() :: [Action.t()]
  def definitions do
    [
      %Action{
        id: "sponsor_proposal.claim",
        permission: "sponsors.proposals.claim",
        target_type: "sponsor_proposal",
        target: ProposalTarget,
        reasons: ProposalReview.reasons(:claim),
        confirmation: :none,
        event: "sponsor_proposal.claimed",
        plan: fn _actor, proposal, _attrs ->
          plan(proposal, :submitted, :under_review, ["review_started"], true)
        end,
        apply: fn actor, proposal, attrs, _now, _plan ->
          ProposalReview.claim!(proposal, actor, attrs)
        end
      },
      %Action{
        id: "sponsor_proposal.request_changes",
        permission: "sponsors.proposals.request_changes",
        target_type: "sponsor_proposal",
        target: ProposalTarget,
        reasons: ProposalReview.reasons(:request_changes),
        params: %{fields: {:array, :string}, message: :string},
        validate: &ProposalReview.validate_change_request/1,
        confirmation: :none,
        event: "sponsor_proposal.changes_requested",
        plan: fn _actor, proposal, _attrs ->
          plan(
            proposal,
            :under_review,
            :changes_requested,
            ["organization_can_edit_requested_answers", "no_notification_sent"],
            true
          )
        end,
        apply: fn actor, proposal, attrs, now, _plan ->
          ProposalReview.request_changes!(proposal, actor, attrs, now)
        end
      },
      %Action{
        id: "sponsor_proposal.accept",
        permission: "sponsors.proposals.accept",
        target_type: "sponsor_proposal",
        target: ProposalTarget,
        reasons: ProposalReview.reasons(:accept),
        confirmation: :required,
        event: "sponsor_proposal.accepted",
        plan: fn _actor, proposal, _attrs ->
          plan(
            proposal,
            :under_review,
            :accepted,
            ["final_decision", "follow_up_outside_product", "nothing_created", "nonbinding"],
            true
          )
        end,
        apply: fn actor, proposal, attrs, now, _plan ->
          ProposalReview.decide!(proposal, actor, attrs, now, :accepted)
        end
      },
      %Action{
        id: "sponsor_proposal.decline",
        permission: "sponsors.proposals.decline",
        target_type: "sponsor_proposal",
        target: ProposalTarget,
        reasons: ProposalReview.reasons(:decline),
        confirmation: :required,
        event: "sponsor_proposal.declined",
        plan: fn _actor, proposal, _attrs ->
          plan(
            proposal,
            :under_review,
            :declined,
            ["final_decision", "nothing_created", "reason_not_shown_to_organization"],
            false
          )
        end,
        apply: fn actor, proposal, attrs, now, _plan ->
          ProposalReview.decide!(proposal, actor, attrs, now, :declined)
        end
      }
    ]
  end

  # `from` -> `to`, and (when `active?`) an active organization.
  defp plan(%{status: from} = proposal, from, to, impact, active?) do
    case ProposalReview.organization(proposal) do
      %{status: status} when active? and status != :active ->
        {:error, {:conflict, %{organization: Atom.to_string(status)}}}

      _organization ->
        {:ok, %{from_state: Atom.to_string(from), to_state: Atom.to_string(to), impact: impact}}
    end
  end

  defp plan(%{status: status}, _from, _to, _impact, _active?),
    do: {:error, {:conflict, %{status: Atom.to_string(status)}}}
end
