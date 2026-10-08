defmodule SimpleFit.EntryConsentVersionsTest do
  # Changes application configuration: not async.
  use SimpleFit.DataCase, async: false

  import SimpleFit.AccountRegistrationHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.Consents
  alias SimpleFit.Entry

  setup do
    previous = Application.fetch_env!(:simple_fit, Consents)
    on_exit(fn -> Application.put_env(:simple_fit, Consents, previous) end)
    {:ok, user} = Accounts.register_user(:apple, "entry-v-#{System.unique_integer([:positive])}")
    %{user: user}
  end

  test "a Terms/Privacy version rollover does not reopen completed registration", %{user: user} do
    user = complete_account_registration!(user)

    Application.put_env(:simple_fit, Consents,
      current_versions: %{terms: "terms-v2", privacy: "privacy-v2"}
    )

    assert {:ok, %{destination: :fighter_onboarding, account_registration: :complete}} =
             Entry.resolve(user, %{"intent" => "fighter"})

    assert {:ok, %{destination: :role_selection}} = Entry.resolve(user)
  end

  test "an in-progress registration with an obsolete consent stays gated", %{user: user} do
    {:ok, _} =
      Accounts.update_account_registration(user, %{
        "full_name" => "Alex Kowalski",
        "date_of_birth" => Date.to_iso8601(Date.shift(Date.utc_today(), year: -30)),
        "accept_terms" => true,
        "accept_privacy" => true
      })

    Application.put_env(:simple_fit, Consents,
      current_versions: %{terms: "terms-v2", privacy: "privacy-v1"}
    )

    assert {:ok, %{destination: :account_registration, account_registration: :in_progress}} =
             Entry.resolve(user, %{"intent" => "fighter"})
  end
end
