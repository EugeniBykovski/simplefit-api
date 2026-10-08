defmodule SimpleFit.AccountRegistrationHelpers do
  @moduledoc "Test helper: a user with completed shared account registration (ADR 0016)."

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User

  @doc "Completes account registration for `user` through the public API."
  @spec complete_account_registration!(User.t()) :: User.t()
  def complete_account_registration!(%User{} = user) do
    {:ok, _} =
      Accounts.update_account_registration(user, %{
        "full_name" => "Test Person",
        "date_of_birth" => Date.to_iso8601(Date.shift(Date.utc_today(), year: -30)),
        "accept_terms" => true,
        "accept_privacy" => true
      })

    {:ok, %{status: :complete}} = Accounts.complete_account_registration(user)
    user
  end
end
