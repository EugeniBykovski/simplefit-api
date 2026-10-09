defmodule SimpleFit.FighterOnboardingHelpers do
  @moduledoc "Test helper: a user with completed Fighter onboarding (ADR 0015)."

  import SimpleFit.AccountRegistrationHelpers

  alias SimpleFit.Accounts.User
  alias SimpleFit.Fighters

  @doc "Completes account registration and Fighter onboarding for `user` through the public API."
  @spec complete_fighter_onboarding!(User.t()) :: User.t()
  def complete_fighter_onboarding!(%User{} = user) do
    complete_account_registration!(user)

    {:ok, _} =
      Fighters.update_profile(user, %{
        "display_name" => "Alex K.",
        "username" => "fighter_#{System.unique_integer([:positive])}",
        "country_code" => "PL",
        "city" => "Warsaw",
        "experience_level" => "amateur",
        "stance" => "orthodox"
      })

    {:ok, _} = Fighters.complete_onboarding(user)
    user
  end
end
