defmodule SimpleFitWeb.CoachFighterJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.CoachFighterController`
  (`CoachFighterRelationship`). Entries are the allowlisted projections built
  by `SimpleFit.Coaching`; nothing else is added.
  """

  alias SimpleFitWeb.CoachingJSON

  def index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{relationships: Enum.map(entries, &entry/1), next_cursor: cursor}

  def show(%{entry: entry}), do: %{relationship: entry(entry)}

  defp entry(entry) do
    entry
    |> CoachingJSON.lifecycle()
    |> Map.merge(%{
      disclosure_version: entry.disclosure_version,
      disclosed_fields: Enum.map(entry.disclosed_fields, &Atom.to_string/1),
      fighter: entry.fighter && CoachingJSON.fighter(entry.fighter),
      fighter_display_name_at_end: entry.fighter_display_name_at_end
    })
  end
end
