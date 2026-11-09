defmodule SimpleFitWeb.OperatorJSON do
  @moduledoc """
  Operator DTOs (SF-110, SF-111). Explicit fields only: no credential material,
  challenge bytes, confirmation token hashes, emails or names. Audit events go
  through `SimpleFit.Operators.Redaction`'s allowlist.
  """

  alias SimpleFit.Operators
  alias SimpleFit.Operators.{Credential, Redaction, StepUp}

  def me(%{view: view}) do
    op = view.operator

    %{
      operator: %{
        id: op.id,
        status: Atom.to_string(op.status),
        permissions: view.permissions,
        security_keys: %{registered: view.registered_keys, required: view.required_keys},
        step_up: step_up(view.step_up),
        enrollment_expires_at: if(op.status == :pending_enrollment, do: op.enrollment_expires_at),
        activated_at: op.activated_at
      }
    }
  end

  def options(%{options: %{challenge_id: id, options: public_key}}),
    do: %{challenge_id: id, public_key: public_key}

  def registered(%{result: result}) do
    %{
      credential: credential(result.credential),
      status: Atom.to_string(result.operator.status),
      security_keys: %{
        registered: result.registered_keys,
        required: Operators.Policy.required_authenticators()
      }
    }
  end

  def credentials(%{credentials: list}), do: %{credentials: Enum.map(list, &credential/1)}
  def credential_show(%{credential: c}), do: %{credential: credential(c)}
  def step_up_show(%{step_up: s}), do: %{step_up: step_up(s)}

  def operator(%{summary: s}), do: %{operator: summary(s)}
  def operators(%{summaries: list}), do: %{operators: Enum.map(list, &summary/1)}

  def audit_events(%{page: page}),
    do: %{events: Enum.map(page.events, &Redaction.audit_event/1), next_cursor: page.next_cursor}

  def audit_event(%{event: event}), do: %{event: Redaction.audit_event(event)}

  def preview(%{preview: p}) do
    %{
      preview: %{
        action: p.action,
        target: p.target,
        expected_revision: p.expected_revision,
        current_state: p.current_state,
        proposed_state: p.proposed_state,
        permission: p.permission,
        impact: p.impact,
        required_permission: p.required_permission,
        required_assurance: p.required_assurance,
        reason_code: p.reason_code,
        confirmation: %{
          required: p.confirmation.required,
          token: p.confirmation.token,
          expires_at: p.confirmation.expires_at
        }
      }
    }
  end

  defp credential(%Credential{} = c) do
    %{
      id: c.id,
      label: c.label,
      created_at: c.inserted_at,
      last_used_at: c.last_used_at,
      revoked_at: c.revoked_at,
      revoked_reason: c.revoked_reason
    }
  end

  defp step_up(nil), do: nil

  defp step_up(%StepUp{} = s) do
    %{
      verified_at: s.verified_at,
      expires_at: s.expires_at,
      fresh_seconds_remaining: Operators.fresh_remaining(s)
    }
  end

  defp summary(%{operator: op} = s) do
    %{
      id: op.id,
      user_id: op.user_id,
      revision: op.revision,
      status: Atom.to_string(op.status),
      bootstrap: op.bootstrap,
      created_by_operator_id: op.created_by_operator_id,
      permissions: s.permissions,
      security_keys: %{registered: s.registered_keys, required: s.required_keys},
      enrollment_expires_at: if(op.status == :pending_enrollment, do: op.enrollment_expires_at),
      activated_at: op.activated_at,
      suspended_at: op.suspended_at,
      revoked_at: op.revoked_at,
      created_at: op.inserted_at
    }
  end
end
