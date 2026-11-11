defmodule SimpleFitWeb.AdminOversightJSON do
  @moduledoc "Renders operator oversight (SF-123): allowlisted fields only."

  @gym_summary [
    :id,
    :name,
    :gym_type,
    :lifecycle,
    :verification_status,
    :country_code,
    :city,
    :staff_count,
    :created_at
  ]

  def gyms(%{page: page}),
    do: %{gyms: Enum.map(page.gyms, &Map.take(&1, @gym_summary)), next_cursor: page.next_cursor}

  def gym(%{gym: gym}) do
    staff = gym.staff

    %{
      gym:
        gym
        |> Map.take(@gym_summary -- [:staff_count])
        |> Map.merge(%{
          staff_count:
            if(gym.owner, do: 1, else: 0) + staff.manager + staff.coach + staff.front_desk,
          revision: gym.revision,
          owner: gym.owner && Map.take(gym.owner, [:user_id, :short_name]),
          staff: Map.take(staff, [:manager, :coach, :front_desk]),
          staff_invitations_pending: gym.staff_invitations_pending,
          members: Map.take(gym.members, [:active, :requested]),
          verification:
            Map.take(gym.verification, [:status, :revision, :submitted_at, :decided_at])
        })
    }
  end

  def coaches(%{coaches: coaches}),
    do: %{coaches: Enum.map(coaches, &summary(&1, [:brand_name]))}

  def coach(%{coach: coach}) do
    %{
      coach:
        coach
        |> Map.take([
          :id,
          :user_id,
          :display_name,
          :brand_name,
          :country_code,
          :city,
          :languages,
          :coaching_formats,
          :competition_levels,
          :profile_status,
          :account_status,
          :created_at
        ])
        |> Map.merge(%{
          relationships: Map.take(coach.relationships, [:active, :ended, :invitations_pending]),
          gyms: Enum.map(coach.gyms, &Map.take(&1, [:gym_id, :since]))
        })
    }
  end

  def fighters(%{fighters: fighters}),
    do: %{fighters: Enum.map(fighters, &summary(&1, [:username]))}

  def fighter(%{fighter: fighter}) do
    %{
      fighter:
        fighter
        |> Map.take([
          :id,
          :user_id,
          :display_name,
          :username,
          :country_code,
          :city,
          :experience_level,
          :stance,
          :profile_status,
          :account_status,
          :created_at,
          :gym_memberships
        ])
        |> Map.put(:relationships, Map.take(fighter.relationships, [:active, :ended]))
    }
  end

  defp summary(profile, extra) do
    Map.take(
      profile,
      [:id, :user_id, :display_name, :profile_status, :account_status, :active_relationships] ++
        extra
    )
  end
end
