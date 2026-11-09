defmodule SimpleFitWeb.AdminSponsorApplicationJSON do
  @moduledoc "The operator's view of a sponsor application (SF-114). No storage keys, no file names."

  alias SimpleFit.Sponsors.{ApplicationPolicy, ApplicationSubmission}
  alias SimpleFitWeb.SponsorApplicationJSON

  def show(%{review: r}) do
    a = r.application

    %{
      application: %{
        application_id: a.id,
        status: Atom.to_string(a.status),
        revision: a.revision,
        submitted_at: a.submitted_at,
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
