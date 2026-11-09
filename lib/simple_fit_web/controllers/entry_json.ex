defmodule SimpleFitWeb.EntryJSON do
  @moduledoc "JSON rendering for `SimpleFitWeb.EntryController` (`EntryResponse`)."

  alias SimpleFit.Entry

  @spec show(%{entry: Entry.t()}) :: %{entry: map()}
  def show(%{entry: entry}) do
    %{
      entry: %{
        destination: entry.destination,
        reason: entry.reason,
        mandatory: entry.mandatory,
        intent: entry.intent,
        context: entry.context,
        gym_id: entry.gym_id,
        account_registration: entry.account_registration,
        fighter_profile: entry.fighter_profile,
        coach_profile: entry.coach_profile,
        capabilities: Enum.map(entry.capabilities, &capability/1),
        gym_workspaces: Enum.map(entry.gym_workspaces, &gym_workspace/1),
        gym_workspace_count: entry.gym_workspace_count,
        sponsor_id: entry.sponsor_id,
        sponsor_workspaces: Enum.map(entry.sponsor_workspaces, &sponsor_workspace/1),
        sponsor_workspace_count: entry.sponsor_workspace_count
      }
    }
  end

  # Only the viewer's own facts about each gym; fields picked explicitly.
  defp gym_workspace(workspace) do
    %{
      gym_id: workspace.gym_id,
      name: workspace.name,
      role: Atom.to_string(workspace.role),
      setup_status: Atom.to_string(workspace.setup_status),
      available_actions: Enum.map(workspace.available_actions, &Atom.to_string/1),
      selected: workspace.selected
    }
  end

  # Only the organization's display name and the viewer's own role (SF-112).
  defp sponsor_workspace(workspace) do
    %{
      sponsor_id: workspace.sponsor_id,
      display_name: workspace.display_name,
      role: Atom.to_string(workspace.role),
      selected: workspace.selected
    }
  end

  # The client route registry's capability vocabulary.
  defp capability(:fighter), do: "FIGHTER"
  defp capability(:coach), do: "COACH"
  defp capability(:gym_workspace), do: "GYM_WORKSPACE"
  defp capability(:sponsor_workspace), do: "SPONSOR_WORKSPACE"
end
