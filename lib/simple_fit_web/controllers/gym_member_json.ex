defmodule SimpleFitWeb.GymMemberJSON do
  @moduledoc """
  JSON rendering of gym members, join requests, enrollment settings, member
  invitations and the member-list preview (SF-95). Views are the
  projections built by `SimpleFit.Gyms`; fields are picked explicitly.
  Never a token, digest, join-code digest, email of a member or user id.
  """

  def index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{members: Enum.map(entries, &member/1), next_cursor: cursor}

  def show(%{member: view}), do: %{member: member(view)}

  def my_index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{memberships: Enum.map(entries, &membership/1), next_cursor: cursor}

  def my_show(%{membership: view}), do: %{membership: membership(view)}

  def join_preview(%{preview: preview}),
    do: %{
      preview: %{gym: %{name: preview.gym.name}, requires_approval: preview.requires_approval}
    }

  def enrollment(%{settings: settings}) do
    %{
      enrollment: %{
        join_code: settings.join_code,
        join_code_rotated_at: settings.join_code_rotated_at,
        auto_approve: settings.auto_approve,
        auto_approve_changed_at: settings.auto_approve_changed_at,
        can_manage: settings.can_manage
      }
    }
  end

  def gym_invitation_index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{invitations: Enum.map(entries, &gym_invitation/1), next_cursor: cursor}

  def gym_invitation_show(%{invitation: view}), do: %{invitation: gym_invitation(view)}

  def my_invitation_index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{invitations: Enum.map(entries, &my_invitation/1), next_cursor: cursor}

  def my_invitation_show(%{invitation: view}), do: %{invitation: my_invitation(view)}

  def invitation_preview(%{preview: preview}) do
    %{
      preview: %{
        gym: %{name: preview.gym.name},
        invited_by: inviter(preview.invited_by),
        expires_at: preview.expires_at
      }
    }
  end

  def accepted(%{result: result}) do
    %{
      invitation: my_invitation(result.invitation),
      gym_id: result.gym_id,
      gym_member_id: result.gym_member_id,
      outcome: Atom.to_string(result.outcome)
    }
  end

  def import_preview(%{preview: preview}) do
    %{
      preview: %{
        persisted: false,
        commit: preview.commit,
        delimiter: preview.delimiter,
        columns:
          Enum.map(preview.columns, fn column ->
            %{header: column.header, field: column.field, status: Atom.to_string(column.status)}
          end),
        summary: preview.summary,
        rows:
          Enum.map(preview.rows, fn row ->
            %{
              line: row.line,
              email: row.email,
              name_present: row.name_present,
              outcome: Atom.to_string(row.outcome),
              duplicate_of_line: row.duplicate_of_line
            }
          end)
      }
    }
  end

  defp member(view), do: view |> facts() |> Map.put(:name, view.name)

  defp membership(view),
    do: view |> facts() |> Map.put(:gym, %{gym_id: view.gym.gym_id, name: view.gym.name})

  defp facts(view) do
    %{
      gym_member_id: view.gym_member_id,
      status: Atom.to_string(view.status),
      joined_via: Atom.to_string(view.joined_via),
      auto_approved: view.auto_approved,
      requested_at: view.requested_at,
      joined_at: view.joined_at,
      responded_at: view.responded_at,
      ended_at: view.ended_at,
      ended_reason: view.ended_reason && Atom.to_string(view.ended_reason)
    }
  end

  defp gym_invitation(view) do
    %{
      invitation_id: view.invitation_id,
      status: Atom.to_string(view.status),
      recipient_email: view.recipient_email,
      invited_by: %{
        staff_membership_id: view.invited_by.staff_membership_id,
        name: view.invited_by.name
      },
      created_at: view.created_at,
      expires_at: view.expires_at,
      last_sent_at: view.last_sent_at,
      resends_remaining: view.resends_remaining,
      responded_at: view.responded_at,
      gym_member_id: view.gym_member_id
    }
  end

  defp my_invitation(view) do
    %{
      invitation_id: view.invitation_id,
      status: Atom.to_string(view.status),
      gym: %{gym_id: view.gym.gym_id, name: view.gym.name},
      invited_by: inviter(view.invited_by),
      sent_to: view.sent_to,
      created_at: view.created_at,
      expires_at: view.expires_at,
      responded_at: view.responded_at,
      gym_member_id: view.gym_member_id
    }
  end

  defp inviter(%{first_name: first_name, role: role}),
    do: %{first_name: first_name, role: role && Atom.to_string(role)}
end
