defmodule SimpleFitWeb.TrainingJSON do
  @moduledoc """
  JSON rendering of training sessions (`CoachTrainingSession`,
  `MyTrainingSession`). Views are the projections built by
  `SimpleFit.Training`; nothing else is added.
  """

  def coach_index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{training_sessions: Enum.map(entries, &coach/1), next_cursor: cursor}

  def coach_show(%{session: session}), do: %{training_session: coach(session)}

  def fighter_index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{training_sessions: Enum.map(entries, &fighter/1), next_cursor: cursor}

  def fighter_show(%{session: session}), do: %{training_session: fighter(session)}

  defp coach(view), do: Map.put(plan(view), :fighter, view.fighter)

  defp fighter(view) do
    plan(view)
    |> Map.merge(%{coach: view.coach, coach_display_name_at_end: view.coach_display_name_at_end})
  end

  defp plan(view) do
    %{
      id: view.id,
      relationship_id: view.relationship_id,
      title: view.title,
      training_type: Atom.to_string(view.training_type),
      starts_at: view.starts_at,
      time_zone: view.time_zone,
      duration_minutes: view.duration_minutes,
      notes: view.notes,
      status: Atom.to_string(view.status),
      completed_at: view.completed_at,
      cancelled_at: view.cancelled_at,
      cancelled_by: view.cancelled_by && Atom.to_string(view.cancelled_by),
      cancel_reason: view.cancel_reason && Atom.to_string(view.cancel_reason),
      inserted_at: view.inserted_at,
      updated_at: view.updated_at
    }
  end
end
