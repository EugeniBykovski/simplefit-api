defmodule SimpleFit.CoachingLegalPolicyTest do
  @moduledoc """
  The SF-72 acceptance policy shared by the token and the id paths: the
  published document, the language actually presented, the fighter's age
  (18+), the evidence committed with the relationship, the coach's
  data-rules acknowledgement evidence, rollover and the emergency gate.
  """

  # Not async: the registry and the sharing configuration are global.
  use SimpleFit.DataCase, async: false

  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers
  import SimpleFit.LegalHelpers

  alias SimpleFit.{Accounts, Coaching, Fighters, Legal}
  alias SimpleFit.Coaching.{Activation, Invitation, Relationship}
  alias SimpleFit.Legal.{Evidence, Registry}

  @ip "203.0.113.72"

  setup do
    configure_sharing()
    reset_rate_limits()
    :ok
  end

  defp address, do: "policy-#{System.unique_integer([:positive])}@example.com"

  defp invite_to!(coach, email) do
    reset_rate_limits()
    invite!(coach, email)
  end

  defp by_token(user, token, language \\ "en"),
    do:
      Coaching.accept_invitation(
        user,
        %{"token" => token, "disclosure_version" => version(), "document_language" => language},
        @ip
      )

  defp by_id(user, id, language \\ "en"),
    do:
      Coaching.accept_incoming_invitation(
        user,
        id,
        %{"disclosure_version" => version(), "document_language" => language},
        @ip
      )

  defp evidence(where), do: Repo.all(from(e in Evidence, where: ^where))
  defp relationships, do: Repo.aggregate(Relationship, :count)

  # A fighter with the email identity `email` born on `born`.
  defp fighter_born!(email, %Date{} = born) do
    {:ok, user} = Accounts.register_user(:email, email)

    {:ok, _} =
      Accounts.update_account_registration(user, %{
        "full_name" => "Policy Fighter",
        "date_of_birth" => Date.to_iso8601(born),
        "accept_terms" => true,
        "accept_privacy" => true
      })

    {:ok, %{status: :complete}} = Accounts.complete_account_registration(user)

    {:ok, _} =
      Fighters.update_profile(user, %{
        "display_name" => "Policy F.",
        "username" => "policy_#{System.unique_integer([:positive])}",
        "country_code" => "PL",
        "city" => "Warsaw",
        "experience_level" => "amateur",
        "stance" => "orthodox"
      })

    {:ok, _} = Fighters.complete_onboarding(user)
    user
  end

  describe "language actually presented" do
    test "an approved language is accepted and recorded; another one is refused, nothing consumed" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      {invitation, token} = invite_to!(coach, email)

      for language <- ["ru", "de", "xx", "EN"] do
        assert by_token(fighter, token, language) ==
                 {:error, {:conflict, %{document_language: "unavailable"}}}
      end

      assert {:error, %Ecto.Changeset{errors: [document_language: _]}} =
               Coaching.accept_invitation(
                 fighter,
                 %{"token" => token, "disclosure_version" => version()},
                 @ip
               )

      assert Repo.get!(Invitation, invitation.id).status == :pending
      assert relationships() == 0

      assert {:ok, %{relationship_id: rel_id}} = by_token(fighter, token, "pl")

      {:ok, %{languages: %{"pl" => pl}}} =
        Registry.get("fighter-coach-disclosure", version())

      assert [e] = evidence(dynamic([e], e.invitation_id == ^invitation.id))
      assert e.kind == :fighter_disclosure_acceptance
      assert e.subject_user_id == fighter.id
      assert e.counterparty_user_id == coach.id
      assert e.relationship_id == rel_id
      assert e.document_id == "fighter-coach-disclosure"
      assert e.document_version == version()
      assert e.document_language == "pl"
      assert e.content_sha256 == pl.content_sha256
    end

    test "the preview presents only an approved variant of the requested language" do
      coach = inviting_coach!()
      email = address()
      {_invitation, token} = invite_to!(coach, email)

      {:ok, %{document: pl}} = Coaching.preview_invitation(token, @ip, "pl")
      assert pl.language == "pl" and pl.summary =~ "TEST FIXTURE"
      assert pl.available_languages == ["en", "pl"]

      {:ok, %{document: ru}} = Coaching.preview_invitation(token, @ip, "ru")
      assert ru.requested_language == "ru"
      assert ru.language == nil and ru.summary == nil and ru.full == nil
      assert ru.version == version()

      {:ok, %{document: none}} = Coaching.preview_invitation(token, @ip)
      assert none.requested_language == nil and none.language == nil
    end
  end

  describe "18+" do
    test "boundaries, on both paths, evaluated on the UTC−12 date" do
      day = Activation.eligibility_date()

      cases = [
        {Date.shift(day, year: -18), :ok},
        {Date.shift(day, year: -18, day: 1), :too_young},
        {Date.shift(day, year: -17), :too_young},
        {Date.shift(day, year: -40), :ok}
      ]

      for {{born, expected}, n} <- Enum.with_index(cases), path <- [:token, :id] do
        email = address()
        fighter = fighter_born!(email, born)
        {invitation, token} = invite_to!(inviting_coach!("Coach #{n}#{path}"), email)

        result =
          if path == :token, do: by_token(fighter, token), else: by_id(fighter, invitation.id)

        case expected do
          :ok ->
            assert {:ok, %{outcome: :created}} = result

          :too_young ->
            assert {:error, %Ecto.Changeset{errors: [coaching_age: {_, opts}]}} = result
            assert opts[:validation] == :too_young
            assert Repo.get!(Invitation, invitation.id).status == :pending
            assert evidence(dynamic([e], e.invitation_id == ^invitation.id)) == []
        end
      end
    end

    test "eligible?/2 by calendar date, including 29 February" do
      user_born = fn born ->
        email = address()
        fighter_born!(email, born)
      end

      leap = user_born.(~D[2008-02-29])
      refute Activation.eligible?(leap, ~D[2026-02-28])
      assert Activation.eligible?(leap, ~D[2026-03-01])

      regular = user_born.(~D[2008-06-15])
      refute Activation.eligible?(regular, ~D[2026-06-14])
      assert Activation.eligible?(regular, ~D[2026-06-15])
    end

    test "no completed registration means no date of birth and no eligibility" do
      {:ok, user} = Accounts.register_user(:email, address())
      assert Accounts.date_of_birth(user) == nil
      refute Activation.eligible?(user, Activation.eligibility_date())
    end

    test "the eligibility date is never ahead of any time zone" do
      utc_today = Date.utc_today()
      assert Date.diff(utc_today, Activation.eligibility_date()) in [0, 1]
    end
  end

  describe "evidence" do
    test "survives the deletion of the invitation, the relationship and both accounts; never updated" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      {invitation, token} = invite_to!(coach, email)
      {:ok, _} = by_token(fighter, token)

      [row] = evidence(dynamic([e], e.invitation_id == ^invitation.id))

      Repo.delete_all(from(u in Accounts.User, where: u.id in ^[coach.id, fighter.id]))
      refute Repo.get(Invitation, invitation.id)
      assert Repo.get!(Evidence, row.id) == row

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(e in Evidence, where: e.id == ^row.id),
          set: [document_language: "pl"]
        )
      end
    end

    test "an already connected pair still records the acceptance of that invitation, once" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      existing = activate!(coach, fighter)
      {invitation, token} = invite_to!(coach, email)

      assert {:ok, %{outcome: :already_connected, relationship_id: id}} = by_token(fighter, token)
      assert id == existing.id
      assert [e] = evidence(dynamic([e], e.invitation_id == ^invitation.id))
      assert e.relationship_id == existing.id
    end

    test "the coach's acknowledgement is recorded once per version with the language shown" do
      coach = coach_user!()

      assert Coaching.acknowledge_coach_data_rules(coach, %{
               "document_version" => data_rules_version(),
               "document_language" => "ru"
             }) == {:error, {:conflict, %{document_language: "unavailable"}}}

      assert {:error, %Ecto.Changeset{errors: [document_language: _]}} =
               Coaching.acknowledge_coach_data_rules(coach, %{
                 "document_version" => data_rules_version()
               })

      for _ <- 1..2 do
        assert {:ok, %{document: %{language: "pl"}, acknowledged_at: %DateTime{}}} =
                 Coaching.acknowledge_coach_data_rules(coach, %{
                   "document_version" => data_rules_version(),
                   "document_language" => "pl"
                 })
      end

      assert [e] = evidence(dynamic([e], e.subject_user_id == ^coach.id))
      assert e.kind == :coach_data_rules_acknowledgement
      assert e.document_version == data_rules_version() and e.document_language == "pl"
      assert e.invitation_id == nil and e.counterparty_user_id == nil
    end
  end

  describe "readiness, rollover and emergency shutdown" do
    test "the gate flag alone is not enough: every global prerequisite is required" do
      assert Coaching.sharing_ready?()

      for opts <- [[enabled: false], [current: nil], [disclosures: %{}], [data_rules: nil]] do
        set_sharing(opts)
        refute Coaching.sharing_ready?(), inspect(opts)
        set_sharing([])
      end

      build_registry!(
        standard_specs()
        |> Enum.map(fn
          %{document_id: "coach-data-rules"} = s -> Map.put(s, :status, "approved")
          s -> s
        end)
      )

      refute Coaching.sharing_ready?()
    end

    test "a withdrawn current disclosure stops new acceptance and what coaches see" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      relationship = activate!(coach, fighter)
      {_invitation, token} = invite_to!(coach, email)

      build_registry!([
        %{
          document_id: "fighter-coach-disclosure",
          version: version(),
          scope: "basic_profile",
          status: "withdrawn"
        },
        %{document_id: "coach-data-rules", version: data_rules_version()}
      ])

      refute Coaching.sharing_ready?()
      assert by_token(fighter, token) == {:error, :not_found}
      assert Coaching.get_coach_relationship(coach, relationship.id) == {:error, :not_found}

      # The fighter keeps their own history and can still end it.
      assert {:ok, %{status: :active}} =
               Coaching.get_fighter_relationship(fighter, relationship.id)

      assert :ok = Coaching.end_relationship(fighter, :fighter, relationship.id)
    end

    test "a published successor never widens a relationship accepted under the old version" do
      coach = coach_user!()
      fighter = fighter_user!()
      relationship = activate!(coach, fighter)

      build_registry!([
        %{
          document_id: "fighter-coach-disclosure",
          version: version(),
          scope: "basic_profile",
          status: "superseded"
        },
        %{
          document_id: "fighter-coach-disclosure",
          version: "fighter-coach-disclosure-test-2",
          scope: "basic_profile"
        },
        %{document_id: "coach-data-rules", version: data_rules_version()}
      ])

      set_sharing(
        disclosures: %{
          "fighter-coach-disclosure-test-2" => :basic_profile,
          version() => :basic_profile
        },
        current: "fighter-coach-disclosure-test-2"
      )

      assert {:ok, entry} = Coaching.get_coach_relationship(coach, relationship.id)
      assert entry.disclosure_version == version()

      assert entry.disclosed_fields ==
               ~w(display_name username country_code city experience_level stance amateur_bout_count)a

      assert Repo.get!(Relationship, relationship.id).disclosure_version == version()
    end

    test "gate off and on again never reactivates an ended relationship nor widens access" do
      coach = coach_user!()
      fighter = fighter_user!()
      kept = activate!(coach, fighter)
      ended = activate!(coach_user!("Coach B"), fighter)
      :ok = Coaching.end_relationship(fighter, :fighter, ended.id)

      set_sharing(enabled: false)
      assert Coaching.get_coach_relationship(coach, kept.id) == {:error, :not_found}
      set_sharing([])

      assert Repo.get!(Relationship, ended.id).status == :ended

      assert {:ok, %{status: :active, disclosed_fields: fields}} =
               Coaching.get_coach_relationship(coach, kept.id)

      assert length(fields) == 7
      refute :weight_class in fields
    end
  end

  test "Legal.ref never falls back to another language" do
    {:ok, ref} = Legal.ref("coach-data-rules", data_rules_version(), "de")
    assert ref.language == nil and ref.title == nil and ref.content_sha256 == nil
    assert ref.available_languages == ["en", "pl"]
  end
end
