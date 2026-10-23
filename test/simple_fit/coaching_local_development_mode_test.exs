defmodule SimpleFit.CoachingLocalDevelopmentModeTest do
  @moduledoc """
  The Coach–Fighter workflow in LOCAL DEVELOPMENT mode (SF-81, ADR 0025), on
  PostgreSQL, with **no** legal configuration at all (gate off, no
  disclosure, no data rules), against the same workflow with the mode off.

  What the mode removes: the data rules, the disclosure text, its language
  and the legal evidence. What it never removes: authentication, recipient
  binding, explicit acceptance (echoing the disclosure the preview showed),
  completed profiles, 18+, replay protection and authorization.
  """

  # Not async: the mode and the sharing configuration are global.
  use SimpleFit.DataCase, async: false
  use Oban.Testing, repo: SimpleFit.Repo

  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.{Accounts, Coaches, Coaching, Fighters, Training}
  alias SimpleFit.Coaching.{DataRulesAcknowledgement, Invitation, LegalPolicy, LocalDevelopment}
  alias SimpleFit.Coaching.Relationship
  alias SimpleFit.Legal.Evidence

  @ip "203.0.113.81"
  @marker "local-development-no-legal-text"

  setup do
    # Nothing legal is configured: production would be :blocked.
    configure_sharing(enabled: false, disclosures: %{}, current: nil, data_rules: nil)
    reset_rate_limits()
    on_exit(fn -> LocalDevelopment.put_active_for_test(false) end)
    :ok
  end

  defp on!, do: LocalDevelopment.put_active_for_test(true)
  defp off!, do: LocalDevelopment.put_active_for_test(false)

  defp address, do: "dev-mode-#{System.unique_integer([:positive])}@example.com"

  defp accept(user, token, params \\ %{}) do
    Coaching.accept_invitation(
      user,
      Map.merge(%{"token" => token, "disclosure_version" => @marker}, params),
      @ip
    )
  end

  defp fighter_born!(email, %Date{} = born) do
    {:ok, user} = Accounts.register_user(:email, email)

    {:ok, _} =
      Accounts.update_account_registration(user, %{
        "full_name" => "Young Fighter",
        "date_of_birth" => Date.to_iso8601(born),
        "accept_terms" => true,
        "accept_privacy" => true
      })

    {:ok, %{status: :complete}} = Accounts.complete_account_registration(user)

    {:ok, _} =
      Fighters.update_profile(user, %{
        "display_name" => "Young F.",
        "username" => "young_#{System.unique_integer([:positive])}",
        "country_code" => "PL",
        "city" => "Warsaw",
        "experience_level" => "amateur",
        "stance" => "orthodox"
      })

    {:ok, _} = Fighters.complete_onboarding(user)
    user
  end

  defp invite_as(coach, to) do
    {:ok, invitation, :created} = Coaching.invite(coach, %{"email" => to}, @ip)
    {invitation, last_token_to(to)}
  end

  describe "the mode off (production behaviour)" do
    test "with nothing legal configured, coaching is blocked everywhere" do
      off!()
      coach = coach_user!()
      assert LegalPolicy.mode() == :blocked
      refute Coaching.sharing_ready?()
      assert Coaching.list_coach_relationships(coach, %{}) == {:error, :not_found}
      assert Coaching.coach_data_rules(coach) == {:error, :not_found}
      assert {:error, _} = Coaching.invite(coach, %{"email" => address()}, @ip)
      assert LegalPolicy.current_disclosure() == nil
      assert LegalPolicy.disclosure_fields(@marker) == []
      refute LegalPolicy.disclosure_offered?(@marker)
    end

    test "the marker is never acceptable in the approved regime" do
      off!()
      configure_sharing()
      assert LegalPolicy.mode() == :production_approved
      refute LegalPolicy.disclosure_offered?(@marker)
      assert LegalPolicy.disclosure_fields(@marker) == []
      assert LegalPolicy.client_mode() == "approved"

      coach = inviting_coach!()
      to = address()
      {invitation, token} = invite!(coach, to)
      fighter = email_fighter!(to)

      assert {:error, {:conflict, %{disclosure_version: "stale"}}} =
               accept(fighter, token, %{"document_language" => "en"})

      # And the approved regime still needs the language of the text shown.
      assert {:error, %Ecto.Changeset{errors: [document_language: _]}} =
               accept(fighter, token, %{"disclosure_version" => version()})

      assert Repo.get!(Invitation, invitation.id).status == :pending
    end
  end

  describe "the mode on" do
    test "the whole workflow: invite, preview, explicit accept, roster, training" do
      on!()
      assert LegalPolicy.mode() == :local_development_bypass
      assert Coaching.sharing_ready?()

      coach = coach_user!("Dev Coach")
      to = address()

      # No data rules: nothing to show or acknowledge, inviting works at once.
      assert {:ok, rules} = Coaching.coach_data_rules(coach)
      assert rules.legal_mode == "local_development"
      assert rules.document_version == nil and rules.document == nil

      assert Coaching.acknowledge_coach_data_rules(coach, %{"document_version" => "x"}) ==
               {:error, :not_found}

      {invitation, token} = invite_as(coach, to)
      assert invitation.status == :pending

      # The preview: no legal text, the marker to echo, the fields shared.
      assert {:ok, preview} = Coaching.preview_invitation(token, @ip, "en")
      assert preview.legal_mode == "local_development"
      assert preview.document == nil
      assert preview.disclosure.version == @marker
      assert :display_name in preview.disclosure.fields
      refute :date_of_birth in preview.disclosure.fields

      fighter = email_fighter!(to)
      assert {:ok, %{outcome: :created, relationship_id: id}} = accept(fighter, token)

      relationship = Repo.get!(Relationship, id)
      assert relationship.status == :active
      assert relationship.disclosure_version == @marker
      accepted = Repo.get!(Invitation, invitation.id)
      assert accepted.status == :accepted and accepted.accepted_disclosure_version == @marker

      # No fabricated consent or legal evidence, no acknowledgement row.
      assert Repo.aggregate(Evidence, :count) == 0
      assert Repo.aggregate(DataRulesAcknowledgement, :count) == 0

      # The coach's roster shows the fighter's disclosed fields only.
      assert {:ok, %{entries: [entry]}} = Coaching.list_coach_relationships(coach, %{})
      assert entry.relationship_id == id
      assert entry.fighter.display_name
      refute Map.has_key?(entry.fighter, :date_of_birth)

      # Training: assign and complete.
      starts = DateTime.utc_now() |> DateTime.add(-600) |> DateTime.truncate(:second)

      assert {:ok, session, :created} =
               Training.create_session(coach, %{
                 "relationship_id" => id,
                 "client_request_id" => Ecto.UUID.generate(),
                 "title" => "Pads",
                 "training_type" => "pads",
                 "starts_at" => DateTime.to_iso8601(starts),
                 "time_zone" => "Europe/Warsaw",
                 "duration_minutes" => 45
               })

      assert {:ok, completed} = Training.complete_session(fighter, session.id)
      assert completed.status == :completed

      # Turning the mode off fails closed again, existing rows included.
      off!()
      assert Coaching.list_coach_relationships(coach, %{}) == {:error, :not_found}
      assert LegalPolicy.disclosure_fields(@marker) == []
    end

    test "acceptance stays explicit: the disclosure shown must be echoed" do
      on!()
      to = address()
      {invitation, token} = invite_as(coach_user!(), to)
      fighter = email_fighter!(to)

      assert {:error, %Ecto.Changeset{}} =
               Coaching.accept_invitation(fighter, %{"token" => token}, @ip)

      assert {:error, {:conflict, %{disclosure_version: "stale"}}} =
               accept(fighter, token, %{"disclosure_version" => version()})

      assert Repo.get!(Invitation, invitation.id).status == :pending
      assert Repo.aggregate(Relationship, :count) == 0
    end

    test "recipient binding: another account cannot accept (SF-57 answers, as in production)" do
      on!()
      to = address()
      {invitation, token} = invite_as(coach_user!(), to)
      other = email_fighter!(address())

      assert accept(other, token) == {:error, :invitation_recipient_mismatch}
      assert Repo.get!(Invitation, invitation.id).status == :pending

      # Nor by id: the invitation is not in the other account's inbox.
      assert Coaching.accept_incoming_invitation(
               other,
               invitation.id,
               %{"disclosure_version" => @marker},
               @ip
             ) == {:error, :invitation_unavailable}
    end

    test "an unverified-email user cannot accept (verified email identity only)" do
      on!()
      to = address()
      {_invitation, token} = invite_as(coach_user!(), to)
      google_only = fighter_user!()

      assert accept(google_only, token) == {:error, :invitation_recipient_mismatch}
      assert Repo.aggregate(Relationship, :count) == 0
    end

    test "18+ still applies; the invitation stays pending" do
      on!()
      to = address()
      {invitation, token} = invite_as(coach_user!(), to)
      young = fighter_born!(to, Date.shift(Date.utc_today(), year: -17))

      assert {:error, %Ecto.Changeset{errors: [coaching_age: _]}} = accept(young, token)
      assert Repo.get!(Invitation, invitation.id).status == :pending
      assert Repo.aggregate(Relationship, :count) == 0
    end

    test "replay: a consumed, declined or expired token creates nothing" do
      on!()
      coach = coach_user!()
      to = address()
      {_invitation, token} = invite_as(coach, to)
      fighter = email_fighter!(to)
      assert {:ok, %{outcome: :created}} = accept(fighter, token)
      assert accept(fighter, token) == {:error, :invitation_unavailable}

      to2 = address()
      {declined, token2} = invite_as(coach, to2)
      fighter2 = email_fighter!(to2)
      assert :ok = Coaching.decline_invitation(fighter2, %{"token" => token2}, @ip)
      assert accept(fighter2, token2) == {:error, :invitation_unavailable}
      assert Repo.get!(Invitation, declined.id).status == :declined

      assert Repo.aggregate(Relationship, :count) == 1
    end

    test "IDOR: another coach sees neither the relationship nor its sessions" do
      on!()
      coach = coach_user!()
      to = address()
      {_invitation, token} = invite_as(coach, to)
      fighter = email_fighter!(to)
      {:ok, %{relationship_id: id}} = accept(fighter, token)

      stranger = coach_user!("Other Coach")
      assert Coaching.get_coach_relationship(stranger, id) == {:error, :not_found}
      assert {:ok, %{entries: []}} = Coaching.list_coach_relationships(stranger, %{})

      assert {:error, :not_found} =
               Training.create_session(stranger, %{
                 "relationship_id" => id,
                 "client_request_id" => Ecto.UUID.generate(),
                 "title" => "Not mine",
                 "training_type" => "pads",
                 "starts_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                 "time_zone" => "Europe/Warsaw",
                 "duration_minutes" => 30
               })

      assert Coaches.get_profile(stranger)
    end

    test "the E08 lists the fields the local-development acceptance shares" do
      on!()
      to = address()
      {_invitation, _token} = invite_as(coach_user!(), to)
      %{text: text} = last_email_to(to)
      assert text =~ "Display name" or text =~ "display name"
    end
  end
end
