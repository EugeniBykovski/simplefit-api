defmodule SimpleFitWeb.GymSetupJSON do
  @moduledoc """
  JSON rendering of gym setup (`GymSetup`). Views are the projections built
  by `SimpleFit.Gyms`; fields are picked explicitly.
  """

  def show(%{setup: setup}) do
    %{
      setup: %{
        gym_id: setup.gym_id,
        setup_status: Atom.to_string(setup.setup_status),
        revision: setup.revision,
        name: setup.name,
        gym_type: Atom.to_string(setup.gym_type),
        phone: setup.phone,
        website: setup.website,
        tagline: setup.tagline,
        accent_color: setup.accent_color,
        primary_location: setup.primary_location && location(setup.primary_location),
        missing_requirements: Enum.map(setup.missing_requirements, &Atom.to_string/1),
        viewer: %{
          staff_membership_id: setup.viewer.staff_membership_id,
          role: Atom.to_string(setup.viewer.role),
          permissions: Enum.map(setup.viewer.permissions, &Atom.to_string/1)
        }
      }
    }
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
