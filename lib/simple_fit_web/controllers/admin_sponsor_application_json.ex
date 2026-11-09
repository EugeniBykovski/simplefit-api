defmodule SimpleFitWeb.AdminSponsorApplicationJSON do
  @moduledoc """
  The operator's view of sponsor applications (SF-114, SF-116): the queue, one
  application and a document download. No storage keys or file names; the queue
  carries nothing about the contact, budget or goals.
  """

  alias SimpleFit.Sponsors.{ApplicationPolicy, ApplicationSubmission}
  alias SimpleFitWeb.SponsorApplicationJSON

  def index(%{page: page}) do
    %{
      applications:
        Enum.map(page.applications, fn row ->
          a = row.application

          %{
            application_id: a.id,
            status: Atom.to_string(a.status),
            revision: a.revision,
            submitted_at: a.submitted_at,
            decided_at: a.decided_at,
            company_name: row.company_name,
            country_code: row.country_code,
            industry: row.industry,
            submissions: row.submissions,
            submitted_documents: row.submitted_documents,
            change_request_open: row.change_request_open
          }
        end),
      next_cursor: page.next_cursor
    }
  end

  def download(%{download: d}) do
    %{download: %{method: "GET", url: d.url, expires_at: d.expires_at}}
  end

  def show(%{review: r}) do
    a = r.application

    %{
      application: %{
        application_id: a.id,
        status: Atom.to_string(a.status),
        revision: a.revision,
        submitted_at: a.submitted_at,
        decided_at: a.decided_at,
        organization:
          r.organization &&
            %{sponsor_id: r.organization.id, status: Atom.to_string(r.organization.status)},
        history:
          Enum.map(
            r.history,
            &%{
              event: &1.event,
              actor:
                if(&1.actor_user_id == a.applicant_user_id, do: "applicant", else: "operator"),
              from_status: &1.from_status,
              to_status: &1.to_status,
              reason_code: &1.reason_code,
              occurred_at: &1.occurred_at
            }
          ),
        latest_submission: submission(r.latest_submission),
        change_request: SponsorApplicationJSON.change_request(r.change_request),
        evidence:
          Enum.map(
            r.evidence,
            &%{
              evidence_id: &1.id,
              kind: Atom.to_string(&1.kind),
              content_type: &1.content_type,
              byte_size: &1.byte_size,
              scanned: false
            }
          )
      }
    }
  end

  defp submission(nil), do: nil

  defp submission(%ApplicationSubmission{} = s) do
    %{
      submission_id: s.id,
      sequence: s.sequence,
      submitted_at: s.submitted_at,
      policy_version: s.policy_version,
      answers:
        Map.new(ApplicationPolicy.answers(), &{&1, s.snapshot["answers"][Atom.to_string(&1)]}),
      contact_email_verified: s.snapshot["contact_email_verified"] == true,
      declaration_version: s.declaration_version,
      declaration_language: s.declaration_language
    }
  end
end
