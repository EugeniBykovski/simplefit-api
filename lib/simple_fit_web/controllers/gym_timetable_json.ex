defmodule SimpleFitWeb.GymTimetableJSON do
  @moduledoc """
  JSON rendering of the gym timetable (SF-97). Views are the projections
  built by `SimpleFit.Gyms`; fields are picked explicitly. Never an email,
  a user id or anything of another gym.
  """

  @venue ~w(venue_id gym_id gym_location_id name description capacity time_zone status revision
            created_at updated_at)a
  @template ~w(template_id gym_id title description default_duration_minutes default_capacity
               default_venue_id default_instructor status revision created_at updated_at)a
  @series ~w(series_id gym_id template_id title venue instructor time_zone weekdays local_start_time
             duration_minutes capacity starts_on ends_on status revision scheduled_count
             cancelled_count skipped_dates created_at updated_at)a
  @occurrence ~w(occurrence_id gym_id template_id series_id series_local_date title status starts_at
                 ends_at time_zone local_starts_at local_ends_at utc_offset_minutes duration_minutes
                 capacity venue instructor needs_instructor rescheduled cancelled_at cancel_reason
                 revision created_at updated_at)a

  def venues(%{page: %{entries: entries}}),
    do: %{venues: Enum.map(entries, &Map.take(&1, @venue))}

  def venue(%{venue: view}), do: %{venue: Map.take(view, @venue)}

  def templates(%{page: %{entries: entries}}),
    do: %{templates: Enum.map(entries, &Map.take(&1, @template))}

  def template(%{template: view}), do: %{template: Map.take(view, @template)}

  def series_index(%{page: %{entries: entries}}),
    do: %{series: Enum.map(entries, &Map.take(&1, @series))}

  def series(%{series: view}), do: %{series: Map.take(view, @series)}

  def generate(%{series: view, created: created}),
    do: %{series: Map.take(view, @series), created_count: created}

  def occurrences(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{occurrences: Enum.map(entries, &occurrence_view/1), next_cursor: cursor}

  def occurrence(%{occurrence: view}), do: %{occurrence: occurrence_view(view)}

  defp occurrence_view(view) do
    view
    |> Map.take(@occurrence)
    |> Map.update!(:local_starts_at, &NaiveDateTime.to_iso8601/1)
    |> Map.update!(:local_ends_at, &NaiveDateTime.to_iso8601/1)
  end
end
