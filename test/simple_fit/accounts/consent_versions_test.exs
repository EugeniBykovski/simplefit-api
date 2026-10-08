defmodule SimpleFit.Accounts.ConsentVersionsTest do
  # Changes application configuration: not async.
  use SimpleFit.DataCase, async: false

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{AccountConsent, Consents}
  alias SimpleFit.Repo
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

  test "A: an in-progress registration cannot complete with an obsolete Terms version", %{
    user: user
  } do
    {:ok, _} = Accounts.update_account_registration(user, attrs())
    set_versions(%{terms: "terms-v2", privacy: "privacy-v1"})

    registration = Accounts.get_account_registration(user)
    assert registration.status == :in_progress

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
    refute Accounts.registration_complete?(user)

    {:ok, accepted} = Accounts.update_account_registration(user, %{"accept_terms" => true})
    assert %{accepted_version: "terms-v2", current: true} = accepted.consents.terms
    assert {:ok, %{status: :complete}} = Accounts.complete_account_registration(user)
  end

  test "B: a completed registration stays complete after a Terms version change", %{user: user} do
    {:ok, _} = Accounts.update_account_registration(user, attrs())

    {:ok, %{profile: %{registration_completed_at: completed_at}}} =
      Accounts.complete_account_registration(user)

    set_versions(%{terms: "terms-v2", privacy: "privacy-v1"})

    registration = Accounts.get_account_registration(user)
    assert registration.status == :complete
    assert registration.missing_requirements == []
    assert registration.profile.registration_completed_at == completed_at
    assert Accounts.registration_complete?(user)

    assert %{
             accepted: true,
             accepted_version: "terms-v1",
             current_version: "terms-v2",
             current: false
           } =
             registration.consents.terms

    assert registration.consents.privacy.current

    # Completing again stays a no-op: no current-version check reopens it.
    assert {:ok, %{status: :complete, missing_requirements: []} = again} =
             Accounts.complete_account_registration(user)

    assert again.profile.registration_completed_at == completed_at
  end

  test "C: accepting the new version later appends a record and keeps the completion time", %{
    user: user
  } do
    {:ok, _} = Accounts.update_account_registration(user, attrs())

    {:ok, %{profile: %{registration_completed_at: completed_at}}} =
      Accounts.complete_account_registration(user)

    set_versions(%{terms: "terms-v2", privacy: "privacy-v1"})

    {:ok, registration} = Accounts.update_account_registration(user, %{"accept_terms" => true})

    assert %{accepted_version: "terms-v2", current: true} = registration.consents.terms
    assert registration.status == :complete
    assert registration.missing_requirements == []
    assert registration.profile.registration_completed_at == completed_at

    terms_history =
      Repo.all(
        from(c in AccountConsent,
          where: c.user_id == ^user.id and c.kind == :terms,
          order_by: [asc: c.recorded_at],
          select: {c.document_version, c.decision}
        )
      )

    assert terms_history == [{"terms-v1", :accepted}, {"terms-v2", :accepted}]
  end

  test "the account API reports a rolled-over completed registration as complete", %{user: user} do
    {:ok, _} = Accounts.update_account_registration(user, attrs())
    {:ok, _} = Accounts.complete_account_registration(user)
    set_versions(%{terms: "terms-v2", privacy: "privacy-v1"})

    body =
      SimpleFitWeb.AccountProfileJSON.show(%{
        registration: Accounts.get_account_registration(user)
      })

    assert %{registration: %{status: :complete, missing_requirements: []}} = body.account_profile

    assert body.account_profile.consents.terms ==
             %{
               accepted: true,
               accepted_version: "terms-v1",
               accepted_at: body.account_profile.consents.terms.accepted_at,
               current_version: "terms-v2",
               current: false
             }
  end
end
