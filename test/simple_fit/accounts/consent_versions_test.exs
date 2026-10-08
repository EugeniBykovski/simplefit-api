defmodule SimpleFit.Accounts.ConsentVersionsTest do
  # Changes application configuration: not async.
  use SimpleFit.DataCase, async: false

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.Consents
  alias SimpleFitWeb.ChangesetErrors

  setup do
    previous = Application.fetch_env!(:simple_fit, Consents)
    on_exit(fn -> Application.put_env(:simple_fit, Consents, previous) end)
    {:ok, user} = Accounts.register_user(:apple, "versions-#{System.unique_integer([:positive])}")
    %{user: user, previous: previous}
  end

  defp set_versions(versions),
    do: Application.put_env(:simple_fit, Consents, current_versions: versions)

  defp attrs,
    do: %{
      "full_name" => "Alex Kowalski",
      "date_of_birth" => Date.to_iso8601(Date.shift(Date.utc_today(), year: -30)),
      "accept_terms" => true,
      "accept_privacy" => true
    }

  test "the configured versions are terms-v1 and privacy-v1" do
    assert Consents.current_version(:terms) == "terms-v1"
    assert Consents.current_version(:privacy) == "privacy-v1"
  end

  test "a new Terms version makes the earlier acceptance not current for completion", %{
    user: user
  } do
    {:ok, _} = Accounts.update_account_registration(user, attrs())
    set_versions(%{terms: "terms-v2", privacy: "privacy-v1"})

    registration = Accounts.get_account_registration(user)

    assert %{
             accepted: true,
             accepted_version: "terms-v1",
             current_version: "terms-v2",
             current: false
           } =
             registration.consents.terms

    assert registration.missing_requirements == [:terms]

    assert {:error, changeset} = Accounts.complete_account_registration(user)
    assert ChangesetErrors.details(changeset).field_codes == %{"terms" => ["required"]}

    {:ok, accepted} = Accounts.update_account_registration(user, %{"accept_terms" => true})
    assert %{accepted_version: "terms-v2", current: true} = accepted.consents.terms
    assert {:ok, %{status: :complete}} = Accounts.complete_account_registration(user)
  end

  test "a version change does not undo a completed registration", %{user: user} do
    {:ok, _} = Accounts.update_account_registration(user, attrs())
    {:ok, _} = Accounts.complete_account_registration(user)
    set_versions(%{terms: "terms-v1", privacy: "privacy-v2"})

    registration = Accounts.get_account_registration(user)
    assert registration.status == :complete
    refute registration.consents.privacy.current
    assert Accounts.registration_complete?(user)
  end
end
