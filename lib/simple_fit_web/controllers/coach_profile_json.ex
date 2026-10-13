defmodule SimpleFitWeb.CoachProfileJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.CoachProfileController`
  (`CoachProfileResponse`). Fields are picked explicitly; ids, the user id
  and timestamps other than the completion time are not exposed.
  """

  alias SimpleFit.Coaches
  alias SimpleFit.Coaches.CoachProfile

  @spec show(%{profile: CoachProfile.t() | nil}) :: %{coach_profile: map()}
  def show(%{profile: profile}) do
    %{coach_profile: Map.put(fields(profile), :onboarding, onboarding(profile))}
  end

  defp onboarding(profile) do
    %{
      status: Coaches.onboarding_status(profile),
      completed_at: profile && profile.onboarding_completed_at && iso8601(profile),
      missing_requirements: Coaches.missing_requirements(profile)
    }
  end

  defp iso8601(%CoachProfile{onboarding_completed_at: at}), do: DateTime.to_iso8601(at)

  defp fields(nil), do: fields(%CoachProfile{})

  defp fields(%CoachProfile{} = profile) do
    %{
      display_name: profile.display_name,
      brand_name: profile.brand_name,
      country_code: profile.country_code,
      city: profile.city,
      bio: profile.bio,
      languages: profile.languages,
      coaching_formats: profile.coaching_formats,
      competition_levels: profile.competition_levels
    }
  end
end
