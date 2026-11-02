defmodule SimpleFitWeb.GymBookingJSON do
  @moduledoc """
  JSON rendering of gym class bookings and check-ins (SF-99). Views are the
  projections built by `SimpleFit.Gyms`; fields are picked explicitly. A
  member sees only their own bookings; staff a short name and booking facts.
  Never an email, a user id, a profile or anything of another gym.
  """

  @own ~w(booking_id gym_member_id status booked_via confirmed_at cancelled_at cancel_reason
          checked_in_at)a
  @own_class ~w(occurrence_id gym title status starts_at ends_at time_zone local_starts_at
                local_ends_at utc_offset_minutes venue instructor)a
  @member_class ~w(occurrence_id title status starts_at ends_at time_zone local_starts_at
                   local_ends_at utc_offset_minutes duration_minutes venue instructor capacity
                   remaining_capacity booking)a
  @entry ~w(booking_id gym_member_id name status booked_via confirmed_at cancelled_at cancel_reason
            checked_in_at)a
  @check_in ~w(check_in_id booking_id occurrence_id gym_member_id method checked_in_at)a

  def classes(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{classes: Enum.map(entries, &member_class/1), next_cursor: cursor}

  def bookings(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{bookings: Enum.map(entries, &own/1), next_cursor: cursor}

  def booking(%{booking: view}), do: %{booking: own(view)}

  def roster(%{page: %{summary: summary, entries: entries, next_cursor: cursor}}),
    do: %{
      summary: summary,
      bookings: Enum.map(entries, &Map.take(&1, @entry)),
      next_cursor: cursor
    }

  def staff_booking(%{booking: view}),
    do: %{
      booking: Map.take(view, @entry),
      occurrence_id: view.occurrence_id,
      summary: view.summary
    }

  def check_in(%{check_in: view}), do: %{check_in: Map.take(view, @check_in)}

  defp own(view) do
    view
    |> Map.take(@own ++ [:availability])
    |> Map.put(:class, view.class |> Map.take(@own_class) |> local())
  end

  defp member_class(view), do: view |> Map.take(@member_class) |> local()

  defp local(view) do
    view
    |> Map.update!(:local_starts_at, &NaiveDateTime.to_iso8601/1)
    |> Map.update!(:local_ends_at, &NaiveDateTime.to_iso8601/1)
  end
end
