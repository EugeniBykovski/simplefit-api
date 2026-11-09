defmodule SimpleFitWeb.SponsorApplicationJSON do
  @moduledoc "Sponsor application DTOs (SF-113). Fields picked explicitly; no internal ids or digests."

  alias SimpleFit.Sponsors.{Application, ApplicationPolicy, ApplicationSubmission}

  def show(%{view: view}), do: %{application: application(view)}

  def submission(%{submission: %ApplicationSubmission{} = s}) do
    %{
      submission: %{
        submission_id: s.id,
        sequence: s.sequence,
        submitted_at: s.submitted_at,
        policy_version: s.policy_version,
        answers:
          Map.new(ApplicationPolicy.answers(), &{&1, s.snapshot["answers"][Atom.to_string(&1)]}),
        declaration_version: s.declaration_version,
        declaration_language: s.declaration_language
      }
    }
  end

  def policy(%{policy: p}) do
    %{
      policy: %{
        version: p.version,
        steps: Enum.map(p.steps, fn {step, fields} -> %{step: step, fields: fields} end),
        required: p.required,
        industries: p.industries,
        interests: p.interests,
        scopes: p.scopes,
        budget_bands:
          Enum.map(p.budget_bands, &%{code: &1.code, currency: "EUR", min: &1.min, max: &1.max}),
        uploads: p.uploads,
        declaration: p.declaration
      }
    }
  end

  defp application(%{application: %Application{} = a} = view) do
    editable? = a.status in Application.editable_statuses()

    blockers =
      if(view.missing != [], do: ["incomplete"], else: []) ++
        if(view.declaration.available, do: [], else: ["declaration_unavailable"])

    %{
      application_id: a.id,
      status: Atom.to_string(a.status),
      revision: a.revision,
      answers: Map.new(ApplicationPolicy.answers(), &{&1, Map.fetch!(a, &1)}),
      contact_email_verified: false,
      missing_fields: view.missing,
      allowed_actions:
        if(editable?, do: ["edit"], else: []) ++
          if(editable? and blockers == [], do: ["submit"], else: []),
      submit_blockers: if(editable?, do: blockers, else: []),
      submitted_at: a.submitted_at,
      submissions:
        Enum.map(
          view.submissions,
          &%{
            submission_id: &1.id,
            sequence: &1.sequence,
            submitted_at: &1.submitted_at,
            policy_version: &1.policy_version
          }
        ),
      declaration: view.declaration,
      uploads: ApplicationPolicy.uploads(),
      sponsor_id: view.sponsor_id,
      created_at: a.inserted_at,
      updated_at: a.updated_at
    }
  end
end
