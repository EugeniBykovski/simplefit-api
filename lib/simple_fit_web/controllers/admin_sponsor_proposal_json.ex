defmodule SimpleFitWeb.AdminSponsorProposalJSON do
  @moduledoc """
  Partnership proposal DTOs for operators (SF-130). The organization's id, name and
  status, and what was submitted: never its contacts, members or the creating
  member's identity.
  """

  alias SimpleFit.Sponsors.Organization

  def index(%{page: page}) do
    %{
      proposals:
        Enum.map(page.proposals, fn row ->
          p = row.proposal

          %{
            proposal_id: p.id,
            status: p.status,
            revision: p.revision,
            title: p.title,
            interests: p.interests,
            organization: organization(row.organization),
            submitted_at: p.submitted_at,
            submissions: row.submissions,
            change_request_open: row.change_request_open
          }
        end),
      next_cursor: page.next_cursor
    }
  end

  def show(%{review: review}) do
    p = review.proposal

    %{
      proposal: %{
        proposal_id: p.id,
        kind: p.kind,
        status: p.status,
        revision: p.revision,
        organization: organization(review.organization),
        latest_submission: latest(review.latest_submission),
        submissions:
          Enum.map(review.submissions, fn s ->
            %{submission_id: s.id, sequence: s.sequence, submitted_at: s.submitted_at}
          end),
        change_request: change_request(review.change_request),
        history:
          Enum.map(review.history, fn e ->
            %{
              from_status: e.from_status,
              to_status: e.to_status,
              occurred_at: e.occurred_at,
              actor_kind: e.actor_kind,
              reason_code: e.reason_code
            }
          end),
        viewer_is_party: Map.get(review, :viewer_is_party, false),
        submitted_at: p.submitted_at,
        decided_at: p.decided_at,
        withdrawn_at: p.withdrawn_at
      }
    }
  end

  defp organization(%Organization{} = o),
    do: %{sponsor_id: o.id, display_name: o.display_name, status: o.status}

  defp latest(nil), do: nil

  defp latest(submission) do
    answers = submission.snapshot["answers"]

    %{
      submission_id: submission.id,
      sequence: submission.sequence,
      submitted_at: submission.submitted_at,
      policy_version: submission.policy_version,
      answers: %{
        title: answers["title"],
        interests: answers["interests"] || [],
        market_scope: answers["market_scope"],
        market_countries: answers["market_countries"] || [],
        market_cities: answers["market_cities"] || [],
        summary: answers["summary"]
      }
    }
  end

  defp change_request(nil), do: nil

  defp change_request(request) do
    %{
      reason_code: request.reason_code,
      fields: request.fields,
      message: request.message,
      requested_at: request.requested_at
    }
  end
end
