defmodule SimpleFit.EntryCoachTest do
  @moduledoc """
  SF-51: Coach capability and multi-context entry (ADR 0017 as amended,
  SF-49 §5.2 rows E1-E14) over the pure decision rules and persisted state.
  """

  use SimpleFit.DataCase, async: true

  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Coaches
  alias SimpleFit.Coaches.CoachProfile
  alias SimpleFit.Entry
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Fighters
  alias SimpleFit.FirstRun.Outcome
  alias SimpleFit.Repo
  alias SimpleFitWeb.ChangesetErrors

  @intents [nil, :fighter, :coach, :gym, :sponsor]
  @contexts [nil, :fighter, :coach]
  @accounts [:not_started, :in_progress, :complete]
  @statuses [:not_started, :in_progress, :completed]

  @coach %{
    "display_name" => "Coach Marek",
    "country_code" => "PL",
    "city" => "Warsaw",
    "coaching_formats" => ["personal_training"]
  }

  defp facts(overrides) do
    Map.merge(
      %{
        intent: nil,
        context: nil,
        account_registration: :complete,
        fighter_profile: :not_started,
        coach_profile: :not_started,
        last_context: nil
      },
      Map.new(overrides)
    )
  end

  defp outcome(entry), do: {entry.destination, entry.reason, entry.mandatory}

  describe "decide/1: E1-E14, one row at a time" do
    test "E1 account registration first, whatever the intent, context or profiles" do
      for account <- [:not_started, :in_progress],
          intent <- @intents,
          context <- @contexts,
          fighter <- @statuses,
          coach <- @statuses do
        entry =
          Entry.decide(
            facts(
              account_registration: account,
              intent: intent,
              context: context,
              fighter_profile: fighter,
              coach_profile: coach,
              last_context: :coach
            )
          )

        assert outcome(entry) == {:account_registration, :account_registration_incomplete, true}
        # The intent survives as the continuation; a context is never applied.
        assert entry.intent == intent
        assert entry.context == nil
      end
    end

    test "E2-E3 a Fighter intent follows the Fighter profile, whatever the Coach profile" do
      for coach <- @statuses, last <- [nil, :fighter, :coach] do
        f =
          &Entry.decide(
            facts(intent: :fighter, fighter_profile: &1, coach_profile: coach, last_context: last)
          )

        assert outcome(f.(:completed)) == {:fighter_home, :fighter_onboarding_completed, false}

        assert outcome(f.(:in_progress)) ==
                 {:fighter_onboarding, :fighter_onboarding_in_progress, true}

        assert outcome(f.(:not_started)) ==
                 {:fighter_onboarding, :fighter_onboarding_not_started, true}
      end
    end

    test "E4-E5 a Coach intent follows the Coach profile; a completed Fighter never overrides it" do
      for fighter <- @statuses, last <- [nil, :fighter, :coach] do
        c =
          &Entry.decide(
            facts(intent: :coach, coach_profile: &1, fighter_profile: fighter, last_context: last)
          )

        assert outcome(c.(:completed)) == {:coach_home, :coach_onboarding_completed, false}

        assert outcome(c.(:in_progress)) ==
                 {:coach_onboarding, :coach_onboarding_in_progress, true}

        assert outcome(c.(:not_started)) ==
                 {:coach_onboarding, :coach_onboarding_not_started, true}
      end
    end

    test "E6 Gym and Sponsor intents are unchanged and ignore profiles and contexts" do
      for fighter <- @statuses, coach <- @statuses, context <- @contexts do
        base = [fighter_profile: fighter, coach_profile: coach, context: context]

        assert outcome(Entry.decide(facts([intent: :gym] ++ base))) ==
                 {:gym_onboarding, :gym_intent, false}

        assert outcome(Entry.decide(facts([intent: :sponsor] ++ base))) ==
                 {:sponsor_application, :sponsor_intent, false}
      end
    end

    test "E7 a requested completed context opens it, over the remembered choice" do
      entry =
        Entry.decide(
          facts(
            context: :fighter,
            fighter_profile: :completed,
            coach_profile: :completed,
            last_context: :coach
          )
        )

      assert outcome(entry) == {:fighter_home, :requested_context, false}
      assert entry.context == :fighter

      entry = Entry.decide(facts(context: :coach, coach_profile: :completed))
      assert outcome(entry) == {:coach_home, :requested_context, false}
    end

    test "E8 a requested context that is not completed is ignored and starts nothing" do
      entry =
        Entry.decide(
          facts(context: :coach, fighter_profile: :completed, coach_profile: :in_progress)
        )

      assert outcome(entry) == {:fighter_home, :fighter_onboarding_completed, false}
      assert entry.context == nil
      assert entry.capabilities == [:fighter]

      entry = Entry.decide(facts(context: :coach))
      assert outcome(entry) == {:role_selection, :no_role_started, false}
    end

    test "E9 nothing started: role selection" do
      assert outcome(Entry.decide(facts([]))) == {:role_selection, :no_role_started, false}
    end

    test "E10 one onboarding in progress, nothing completed: resume it" do
      assert outcome(Entry.decide(facts(fighter_profile: :in_progress))) ==
               {:fighter_onboarding, :fighter_onboarding_in_progress, true}

      assert outcome(Entry.decide(facts(coach_profile: :in_progress))) ==
               {:coach_onboarding, :coach_onboarding_in_progress, true}
    end

    test "E11 both onboardings in progress: context selection, never a Fighter default" do
      for last <- [nil, :fighter, :coach] do
        entry =
          Entry.decide(
            facts(fighter_profile: :in_progress, coach_profile: :in_progress, last_context: last)
          )

        assert outcome(entry) == {:context_selection, :multiple_roles_in_progress, false}
        assert entry.capabilities == []
      end
    end

    test "E12 one completed profile: its home, the other journey staying unfinished" do
      for other <- [:not_started, :in_progress], last <- [nil, :fighter, :coach] do
        assert outcome(
                 Entry.decide(
                   facts(fighter_profile: :completed, coach_profile: other, last_context: last)
                 )
               ) ==
                 {:fighter_home, :fighter_onboarding_completed, false}

        assert outcome(
                 Entry.decide(
                   facts(coach_profile: :completed, fighter_profile: other, last_context: last)
                 )
               ) ==
                 {:coach_home, :coach_onboarding_completed, false}
      end
    end

    test "E13 both completed: the last explicit choice" do
      both = [fighter_profile: :completed, coach_profile: :completed]

      assert outcome(Entry.decide(facts([last_context: :coach] ++ both))) ==
               {:coach_home, :last_context, false}

      assert outcome(Entry.decide(facts([last_context: :fighter] ++ both))) ==
               {:fighter_home, :last_context, false}
    end

    test "E14 both completed without a choice: context selection, no arbitrary default" do
      assert outcome(Entry.decide(facts(fighter_profile: :completed, coach_profile: :completed))) ==
               {:context_selection, :context_choice_required, false}
    end
  end

  describe "decide/1: properties over every combination" do
    test "capabilities are exactly the completed profiles, never an intent or context" do
      for intent <- @intents,
          context <- @contexts,
          account <- @accounts,
          fighter <- @statuses,
          coach <- @statuses,
          last <- @contexts do
        entry =
          Entry.decide(
            facts(
              intent: intent,
              context: context,
              account_registration: account,
              fighter_profile: fighter,
              coach_profile: coach,
              last_context: last
            )
          )

        expected =
          Enum.filter([:fighter, :coach], fn
            :fighter -> fighter == :completed
            :coach -> coach == :completed
          end)

        assert entry.capabilities == expected
        assert entry.destination in Entry.destinations()
        assert entry.reason in Entry.reasons()
        refute entry.reason == :coach_intent

        assert entry.mandatory ==
                 entry.destination in [
                   :account_registration,
                   :fighter_onboarding,
                   :coach_onboarding
                 ]

        # A home is reached only through its completed profile.
        if entry.destination == :coach_home, do: assert(coach == :completed)
        if entry.destination == :fighter_home, do: assert(fighter == :completed)
      end
    end

    test "facts without Coach state behave exactly as before SF-51 for Fighter-only users" do
      for intent <- [nil, :fighter], fighter <- @statuses do
        old = %{intent: intent, account_registration: :complete, fighter_profile: fighter}
        new = Map.merge(old, %{coach_profile: :not_started, context: nil, last_context: nil})
        assert Entry.decide(old) == Entry.decide(new)
      end
    end
  end

  describe "resolve/2 over persisted state" do
    setup do
      {:ok, user} =
        Accounts.register_user(:google, "entry-coach-#{System.unique_integer([:positive])}")

      %{user: user}
    end

    defp resolve!(user, params \\ %{}) do
      {:ok, entry} = Entry.resolve(user, params)
      entry
    end

    defp coach!(user, complete? \\ true) do
      {:ok, _} = Coaches.update_profile(user, @coach)
      if complete?, do: {:ok, _} = Coaches.complete_onboarding(user)
      user
    end

    test "COACH capability: none, in progress, completed", %{user: user} do
      user = complete_account_registration!(user)
      assert resolve!(user).capabilities == []

      coach!(user, false)
      assert %{capabilities: [], coach_profile: :in_progress} = resolve!(user)

      {:ok, _} = Coaches.complete_onboarding(user)
      assert %{capabilities: [:coach], coach_profile: :completed} = resolve!(user)
    end

    test "Fighter and Coach capabilities are independent and can be held together", %{user: user} do
      complete_fighter_onboarding!(user)
      assert resolve!(user).capabilities == [:fighter]

      coach!(user, false)
      assert resolve!(user).capabilities == [:fighter]
      assert %{destination: :fighter_home} = resolve!(user)

      {:ok, _} = Coaches.complete_onboarding(user)
      assert resolve!(user).capabilities == [:fighter, :coach]
    end

    test "a coach can start Fighter onboarding later; COACH stays", %{user: user} do
      user = complete_account_registration!(user)
      coach!(user)

      assert %{destination: :fighter_onboarding, capabilities: [:coach]} =
               resolve!(user, %{"intent" => "fighter"})

      assert %{destination: :coach_home} = resolve!(user)
    end

    test "the Coach journey from registration: intent survives account registration", %{
      user: user
    } do
      assert %{destination: :account_registration, intent: :coach} =
               resolve!(user, %{"intent" => "coach"})

      user = complete_account_registration!(user)

      assert %{destination: :coach_onboarding, reason: :coach_onboarding_not_started} =
               resolve!(user, %{"intent" => "coach"})

      coach!(user, false)

      assert %{destination: :coach_onboarding, reason: :coach_onboarding_in_progress} =
               resolve!(user, %{"intent" => "coach"})

      # No circular gate: completion needs no COACH capability first.
      {:ok, _} = Coaches.complete_onboarding(user)

      assert %{destination: :coach_home, capabilities: [:coach]} =
               resolve!(user, %{"intent" => "coach"})
    end

    test "a partial Coach profile does not bypass account registration", %{user: user} do
      coach!(user, false)
      assert %{destination: :account_registration} = resolve!(user, %{"intent" => "coach"})
    end

    test "invalid intents and contexts are validation errors, never roles", %{user: user} do
      for params <- [
            %{"intent" => "Coach"},
            %{"intent" => "admin"},
            %{"context" => "gym"},
            %{"context" => "COACH"},
            %{"context" => "sponsor"}
          ] do
        assert {:error, changeset} = Entry.resolve(user, params)

        [{field, ["invalid_choice"]}] =
          Map.to_list(ChangesetErrors.details(changeset).field_codes)

        assert field in ["intent", "context"]
      end
    end

    test "resolution writes nothing: no profile, choice or first-run outcome", %{user: user} do
      user = complete_account_registration!(user)
      complete_fighter_onboarding!(user)

      for intent <- [nil | ~w(fighter coach gym sponsor)], context <- [nil, "fighter", "coach"] do
        resolve!(user, %{"intent" => intent, "context" => context})
      end

      assert Repo.aggregate(CoachProfile, :count) == 0
      assert Repo.aggregate(ContextChoice, :count) == 0
      assert Repo.aggregate(Outcome, :count) == 0
    end
  end

  describe "record_context_choice/2" do
    setup do
      {:ok, user} =
        Accounts.register_user(:google, "entry-choice-#{System.unique_integer([:positive])}")

      complete_fighter_onboarding!(user)
      {:ok, _} = Coaches.update_profile(user, @coach)
      {:ok, _} = Coaches.complete_onboarding(user)
      %{user: user}
    end

    defp choose(user, context), do: Entry.record_context_choice(user, %{"context" => context})

    test "both completed: no choice yet, then the chosen context, switching both ways", %{
      user: user
    } do
      assert {:ok, %{destination: :context_selection}} = Entry.resolve(user)

      assert {:ok, %ContextChoice{context: :coach}} = choose(user, "coach")
      assert {:ok, %{destination: :coach_home, reason: :last_context}} = Entry.resolve(user)

      assert {:ok, %ContextChoice{context: :fighter}} = choose(user, "fighter")
      assert {:ok, %{destination: :fighter_home, reason: :last_context}} = Entry.resolve(user)

      assert {:ok, _} = choose(user, "fighter")
      assert Repo.aggregate(ContextChoice, :count) == 1
    end

    test "an explicit intent or context wins over the remembered choice", %{user: user} do
      {:ok, _} = choose(user, "coach")
      assert {:ok, %{destination: :fighter_home}} = Entry.resolve(user, %{"intent" => "fighter"})

      assert {:ok, %{destination: :fighter_home, reason: :requested_context}} =
               Entry.resolve(user, %{"context" => "fighter"})

      # Neither changed the remembered choice.
      assert {:ok, %{destination: :coach_home}} = Entry.resolve(user)
    end

    test "only a completed context can be chosen" do
      {:ok, user} =
        Accounts.register_user(:google, "entry-choice-b-#{System.unique_integer([:positive])}")

      complete_fighter_onboarding!(user)
      {:ok, _} = Coaches.update_profile(user, @coach)

      assert {:error, :conflict} = choose(user, "coach")
      assert {:ok, %ContextChoice{context: :fighter}} = choose(user, "fighter")
      assert Repo.get(ContextChoice, user.id).context == :fighter
    end

    test "unsupported, missing and extra values are validation errors", %{user: user} do
      for {params, codes} <- [
            {%{"context" => "gym"}, %{"context" => ["invalid_choice"]}},
            {%{"context" => "admin"}, %{"context" => ["invalid_choice"]}},
            {%{}, %{"context" => ["required"]}},
            {%{"context" => nil}, %{"context" => ["required"]}},
            {%{"context" => "coach", "capabilities" => ["COACH"]},
             %{"capabilities" => ["invalid"]}},
            {%{"context" => "coach", "user_id" => Ecto.UUID.generate()},
             %{"user_id" => ["invalid"]}}
          ] do
        assert {:error, changeset} = Entry.record_context_choice(user, params)
        assert ChangesetErrors.details(changeset).field_codes == codes, inspect(params)
      end

      assert Repo.aggregate(ContextChoice, :count) == 0
    end

    test "a remembered choice is re-validated on every read and never grants access", %{
      user: user
    } do
      {:ok, other} =
        Accounts.register_user(:google, "entry-choice-c-#{System.unique_integer([:positive])}")

      complete_fighter_onboarding!(other)

      # A stale row (written before the profile could exist) is ignored.
      Repo.insert!(%ContextChoice{
        user_id: other.id,
        context: :coach,
        chosen_at: DateTime.utc_now()
      })

      assert {:ok, %{destination: :fighter_home, capabilities: [:fighter]}} = Entry.resolve(other)

      # Also when both profiles are complete only after the stale row.
      {:ok, _} = Coaches.update_profile(other, @coach)
      assert {:ok, %{destination: :fighter_home, capabilities: [:fighter]}} = Entry.resolve(other)
      {:ok, _} = Coaches.complete_onboarding(other)
      assert {:ok, %{destination: :coach_home, reason: :last_context}} = Entry.resolve(other)
      # The other user's choice is not this user's.
      assert {:ok, %{destination: :context_selection}} = Entry.resolve(user)
    end

    test "each user has their own choice", %{user: user} do
      {:ok, other} =
        Accounts.register_user(:google, "entry-choice-d-#{System.unique_integer([:positive])}")

      complete_fighter_onboarding!(other)
      {:ok, _} = Coaches.update_profile(other, @coach)
      {:ok, _} = Coaches.complete_onboarding(other)

      {:ok, _} = choose(user, "coach")
      {:ok, _} = choose(other, "fighter")

      assert {:ok, %{destination: :coach_home}} = Entry.resolve(user)
      assert {:ok, %{destination: :fighter_home}} = Entry.resolve(other)
    end

    test "deleting the user deletes the choice", %{user: user} do
      {:ok, _} = choose(user, "coach")
      Repo.delete!(user)
      assert Repo.aggregate(ContextChoice, :count) == 0
    end

    test "the database accepts only profile contexts", %{user: user} do
      assert_raise Postgrex.Error, ~r/context_profile_contexts/, fn ->
        Repo.query!(
          "INSERT INTO entry_context_choices (user_id, context, chosen_at, inserted_at, updated_at) VALUES ($1, 'gym', now(), now(), now())",
          [Ecto.UUID.dump!(user.id)]
        )
      end
    end

    test "no Fighter or Coach data is created or changed by a choice", %{user: user} do
      fighter = Fighters.get_profile(user)
      coach = Coaches.get_profile(user)
      {:ok, _} = choose(user, "coach")
      assert Fighters.get_profile(user) == fighter
      assert Coaches.get_profile(user) == coach
    end
  end
end
