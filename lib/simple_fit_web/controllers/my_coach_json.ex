defmodule SimpleFitWeb.MyCoachJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.MyCoachController` (`MyCoachRelationship`).
  Entries are the projections built by `SimpleFit.Coaching`.
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
      coach:
        entry.coach &&
          %{display_name: entry.coach.display_name, brand_name: entry.coach.brand_name},
      coach_display_name_at_end: entry.coach_display_name_at_end
    })
  end
end
