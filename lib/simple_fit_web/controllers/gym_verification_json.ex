defmodule SimpleFitWeb.GymVerificationJSON do
  @moduledoc """
  JSON rendering of a gym's business verification and go-live readiness
  (SF-103). Fields are picked explicitly: never a storage key, an operator
  identity, a submitter id or the history.
  """

  alias SimpleFit.Gyms.{VerificationApplication, VerificationEvidence}

  def show(%{verification: view}), do: %{verification: verification(view)}

  def evidence(%{verification: view, evidence: evidence, upload: upload}) do
    %{
      verification: verification(view),
      evidence: document(evidence),
      upload: %{
        method: upload.method |> Atom.to_string() |> String.upcase(),
        url: upload.url,
        headers: upload.headers,
        expires_at: upload.expires_at
      }
    }
  end

  def go_live(%{go_live: readiness}) do
    %{
      go_live: %{
        gym_id: readiness.gym_id,
        policy_version: readiness.policy_version,
        evaluated_at: readiness.evaluated_at,
        prerequisites_met: readiness.prerequisites_met,
        checks:
          Enum.map(readiness.checks, fn check ->
            %{
              key: Atom.to_string(check.key),
              status: Atom.to_string(check.status),
              requiredness: Atom.to_string(check.requiredness),
              reason_code: Atom.to_string(check.reason_code),
              action: check.action && Atom.to_string(check.action),
              source: Atom.to_string(check.source)
            }
          end),
        publication: %{
          status: Atom.to_string(readiness.publication.status),
          reason_code: Atom.to_string(readiness.publication.reason_code)
        }
      }
    }
  end

  defp verification(view) do
    %{
      gym_id: view.gym_id,
      status: Atom.to_string(view.status),
      application: application(view.application),
      evidence: Enum.map(view.evidence, &document/1),
      latest_decision:
        view.latest_decision &&
          %{
            decision: Atom.to_string(view.latest_decision.decision),
            reason_code: view.latest_decision.reason_code,
            decided_at: view.latest_decision.decided_at
          },
      missing: Enum.map(view.missing, &Atom.to_string/1),
      can_edit: view.can_edit,
      can_submit: view.can_submit,
      requirements: %{
        policy_version: view.requirements.policy_version,
        required_fields: Enum.map(view.requirements.required_fields, &Atom.to_string/1),
        min_evidence: view.requirements.min_evidence,
        max_evidence: view.requirements.max_evidence,
        max_bytes: view.requirements.max_bytes,
        content_types: view.requirements.content_types,
        kinds: Enum.map(view.requirements.kinds, &Atom.to_string/1)
      }
    }
  end

  defp application(nil), do: nil

  defp application(%VerificationApplication{} = a) do
    %{
      id: a.id,
      revision: a.revision,
      policy_version: a.policy_version,
      legal_name: a.legal_name,
      registration_country: a.registration_country,
      registration_number: a.registration_number,
      address_line: a.address_line,
      postal_code: a.postal_code,
      city: a.city,
      website: a.website,
      submitted_at: a.submitted_at,
      decided_at: a.decided_at,
      created_at: a.inserted_at,
      updated_at: a.updated_at
    }
  end

  defp document(%VerificationEvidence{} = e) do
    %{
      id: e.id,
      kind: Atom.to_string(e.kind),
      status: Atom.to_string(e.status),
      file_name: e.file_name,
      content_type: e.content_type,
      byte_size: e.byte_size,
      uploaded_at: e.uploaded_at,
      submitted: not is_nil(e.submitted_revision),
      created_at: e.inserted_at
    }
  end
end
