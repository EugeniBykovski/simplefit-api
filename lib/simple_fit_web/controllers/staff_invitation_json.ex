defmodule SimpleFitWeb.StaffInvitationJSON do
  @moduledoc """
  JSON rendering of gym staff invitations: the gym's view
  (`GymStaffInvitation`), the recipient's (`MyStaffInvitation`), the link
  preview and an acceptance. Views are the projections built by
  `SimpleFit.Gyms`; fields are picked explicitly. Never a token, digest or
  unmasked address of someone else.
  """

  def gym_index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{invitations: Enum.map(entries, &gym_invitation/1), next_cursor: cursor}

  def gym_show(%{invitation: invitation}), do: %{invitation: gym_invitation(invitation)}

  def my_index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{invitations: Enum.map(entries, &my_invitation/1), next_cursor: cursor}

  def my_show(%{invitation: invitation}), do: %{invitation: my_invitation(invitation)}

  def preview(%{preview: preview}) do
    %{
      preview: %{
        gym: %{name: preview.gym.name},
        role: Atom.to_string(preview.role),
        invited_by: inviter(preview.invited_by),
        expires_at: preview.expires_at
      }
    }
  end

  def accepted(%{result: result}) do
    %{
      invitation: my_invitation(result.invitation),
      gym_id: result.gym_id,
      staff_membership_id: result.staff_membership_id,
      role: Atom.to_string(result.role),
      outcome: Atom.to_string(result.outcome)
    }
  end

  defp gym_invitation(view) do
    %{
      invitation_id: view.invitation_id,
      role: Atom.to_string(view.role),
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
      staff_membership_id: view.staff_membership_id
    }
  end

  defp my_invitation(view) do
    %{
      invitation_id: view.invitation_id,
      status: Atom.to_string(view.status),
      role: Atom.to_string(view.role),
      gym: %{gym_id: view.gym.gym_id, name: view.gym.name},
      invited_by: inviter(view.invited_by),
      sent_to: view.sent_to,
      created_at: view.created_at,
      expires_at: view.expires_at,
      responded_at: view.responded_at,
      staff_membership_id: view.staff_membership_id
    }
  end

  defp inviter(%{first_name: first_name, role: role}),
    do: %{first_name: first_name, role: role && Atom.to_string(role)}
end
