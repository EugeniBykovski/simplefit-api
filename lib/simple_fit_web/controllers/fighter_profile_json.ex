defmodule SimpleFitWeb.FighterProfileJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.FighterProfileController`
  (`FighterProfileResponse`). Fields are picked explicitly; ids, the user id
  and timestamps other than the completion time are not exposed.
  """

  alias SimpleFit.Fighters
  alias SimpleFit.Fighters.FighterProfile

  @spec show(%{profile: FighterProfile.t() | nil}) :: %{fighter_profile: map()}
  def show(%{profile: profile}) do
    %{fighter_profile: Map.put(fields(profile), :onboarding, onboarding(profile))}
  end

  defp onboarding(profile) do
    %{
      status: Fighters.onboarding_status(profile),
      completed_at: profile && profile.onboarding_completed_at && iso8601(profile),
      missing_requirements: Fighters.missing_requirements(profile)
    }
  end

  defp iso8601(%FighterProfile{onboarding_completed_at: at}), do: DateTime.to_iso8601(at)

  defp fields(nil), do: fields(%FighterProfile{})

  defp fields(%FighterProfile{} = profile) do
    %{
      display_name: profile.display_name,
      username: profile.username,
      country_code: profile.country_code,
      city: profile.city,
      experience_level: profile.experience_level,
      bout_count: profile.bout_count,
      stance: profile.stance,
      goals: profile.goals,
      next_fight_on: profile.next_fight_on && Date.to_iso8601(profile.next_fight_on),
      next_fight_name: profile.next_fight_name,
      weight_class: profile.weight_class,
      current_weight_kg: profile.current_weight_kg && Decimal.to_float(profile.current_weight_kg),
      height_cm: profile.height_cm
    }
  end
end
