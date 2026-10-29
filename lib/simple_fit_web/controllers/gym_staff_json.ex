defmodule SimpleFitWeb.GymStaffJSON do
  @moduledoc """
  JSON rendering of a gym's staff (`GymStaffMember`). Views are the
  projections built by `SimpleFit.Gyms`; fields are picked explicitly.
  """

  alias SimpleFit.Gyms.StaffMembership

  def index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{staff: Enum.map(entries, &member/1), next_cursor: cursor}

  def show(%{member: member}), do: %{staff_member: member(member)}

  # An ended membership, as its end returned it (its name is not re-read).
  def ended(%{membership: %StaffMembership{} = m, viewer_id: viewer_id}) do
    %{
      staff_member: %{
        staff_membership_id: m.id,
        role: Atom.to_string(m.role),
        status: Atom.to_string(m.status),
        name: nil,
        is_viewer: m.user_id == viewer_id,
        joined_at: m.inserted_at,
        ended_at: m.ended_at,
        ended_reason: m.ended_reason && Atom.to_string(m.ended_reason)
      }
    }
  end

  defp member(view) do
    %{
      staff_membership_id: view.staff_membership_id,
      role: Atom.to_string(view.role),
      status: Atom.to_string(view.status),
      name: view.name,
      is_viewer: view.is_viewer,
      joined_at: view.joined_at,
      ended_at: view.ended_at,
      ended_reason: view.ended_reason && Atom.to_string(view.ended_reason)
    }
  end
end
