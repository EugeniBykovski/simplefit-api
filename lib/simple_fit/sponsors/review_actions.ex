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

  No approval or rejection exists (a later task). Neither action creates an
  organization, a membership or anything commercial. Neither needs a preview
  confirmation: both are reversible by the applicant's next submission.
  """

  alias SimpleFit.Operators.Action
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
      }
    ]
  end

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
