defmodule SimpleFitWeb.CoachingJSON do
  @moduledoc "Field rendering shared by the Coach–Fighter relationship views (ADR 0021)."

  @doc "The lifecycle fields of an entry."
  def lifecycle(entry) do
    %{
      relationship_id: entry.relationship_id,
      status: Atom.to_string(entry.status),
      started_at: DateTime.to_iso8601(entry.started_at),
      ended_at: entry.ended_at && DateTime.to_iso8601(entry.ended_at),
      ended_by: entry.ended_by && Atom.to_string(entry.ended_by)
    }
  end

  @doc "The fighter projection: exactly the C1 + C2 keys, values as disclosed."
  def fighter(fighter) do
    %{
      display_name: fighter.display_name,
      username: fighter.username,
      country_code: fighter.country_code,
      city: fighter.city,
      experience_level: fighter.experience_level && Atom.to_string(fighter.experience_level),
      stance: fighter.stance && Atom.to_string(fighter.stance),
      amateur_bout_count: fighter.amateur_bout_count
    }
  end
end
