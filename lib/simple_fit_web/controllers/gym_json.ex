defmodule SimpleFitWeb.GymJSON do
  @moduledoc """
  JSON rendering of gyms (`Gym`, `GymSummary`). Views are the projections
  built by `SimpleFit.Gyms`; fields are picked explicitly.
  """

  def index(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{gyms: Enum.map(entries, &gym/1), next_cursor: cursor}

  def show(%{gym: view}), do: %{gym: gym(view)}

  defp gym(view) do
    base = %{
      id: view.id,
      name: view.name,
      gym_type: Atom.to_string(view.gym_type),
      setup_status: Atom.to_string(view.setup_status),
      inserted_at: view.inserted_at,
      updated_at: view.updated_at,
      viewer: %{
        staff_membership_id: view.viewer.staff_membership_id,
        role: Atom.to_string(view.viewer.role),
        permissions: Enum.map(view.viewer.permissions, &Atom.to_string/1)
      }
    }

    case view do
      %{locations: locations} -> Map.put(base, :locations, Enum.map(locations, &location/1))
      _summary -> base
    end
  end

  defp location(location) do
    %{
      id: location.id,
      name: location.name,
      country_code: location.country_code,
      city: location.city,
      address_line: location.address_line,
      entrance_note: location.entrance_note,
      is_primary: location.is_primary
    }
  end
end
