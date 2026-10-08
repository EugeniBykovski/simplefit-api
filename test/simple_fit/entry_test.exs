defmodule SimpleFit.EntryTest do
  use SimpleFit.DataCase, async: true

  import SimpleFit.AccountRegistrationHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{AccountConsent, AccountProfile, User}
  alias SimpleFit.Entry
  alias SimpleFit.Fighters
  alias SimpleFit.Fighters.FighterProfile
  alias SimpleFit.Repo
  alias SimpleFitWeb.ChangesetErrors

  @intents [nil, :fighter, :coach, :gym, :sponsor]
  @accounts [:not_started, :in_progress, :complete]
  @fighters [:not_started, :in_progress, :completed]

  describe "decide/1: the full matrix" do
    # Written out independently of the implementation's clause order.
    defp expected(_intent, account, _fighter) when account != :complete,
      do: {:account_registration, :account_registration_incomplete, true}

    defp expected(:coach, _, _), do: {:coach_onboarding, :coach_intent, false}
    defp expected(:gym, _, _), do: {:gym_onboarding, :gym_intent, false}
    defp expected(:sponsor, _, _), do: {:sponsor_application, :sponsor_intent, false}
    defp expected(_, _, :completed), do: {:fighter_home, :fighter_onboarding_completed, false}

    defp expected(_, _, :in_progress),
      do: {:fighter_onboarding, :fighter_onboarding_in_progress, true}

    defp expected(:fighter, _, :not_started),
      do: {:fighter_onboarding, :fighter_onboarding_not_started, true}

    defp expected(nil, _, :not_started), do: {:role_selection, :no_role_started, false}

    test "every intent x account registration x fighter profile combination" do
      for intent <- @intents, account <- @accounts, fighter <- @fighters do
        facts = %{intent: intent, account_registration: account, fighter_profile: fighter}
        entry = Entry.decide(facts)
        {destination, reason, mandatory} = expected(intent, account, fighter)

        assert {entry.destination, entry.reason, entry.mandatory} ==
                 {destination, reason, mandatory},
               "#{inspect(facts)}"

        assert entry.intent == intent
        assert entry.account_registration == account
        assert entry.fighter_profile == fighter
        assert entry.destination in Entry.destinations()
        assert entry.reason in Entry.reasons()
        assert entry.capabilities == if(fighter == :completed, do: [:fighter], else: [])
      end
    end

    test "no intent never assumes Fighter for a user with no role state" do
      entry =
        Entry.decide(%{
          intent: nil,
          account_registration: :complete,
          fighter_profile: :not_started
        })

      assert entry.destination == :role_selection
      assert entry.capabilities == []
    end

    test "Coach, Gym and Sponsor intents never yield a capability" do
      for intent <- [:coach, :gym, :sponsor], fighter <- @fighters do
        entry =
          Entry.decide(%{
            intent: intent,
            account_registration: :complete,
            fighter_profile: fighter
          })

        refute Enum.any?(entry.capabilities, &(&1 != :fighter))
      end
    end
  end

  describe "resolve/2 over persisted state" do
    setup do
      {:ok, user} = Accounts.register_user(:google, "entry-#{System.unique_integer([:positive])}")
      %{user: user}
    end

    defp resolve!(user, intent \\ nil) do
      params = if intent, do: %{"intent" => intent}, else: %{}
      {:ok, entry} = Entry.resolve(user, params)
      entry
    end

    defp fighter_fields do
      %{
        "display_name" => "Alex K.",
        "username" => "entry_#{System.unique_integer([:positive])}",
        "country_code" => "PL",
        "city" => "Warsaw",
        "experience_level" => "amateur",
        "stance" => "orthodox"
      }
    end

    test "account not_started and in_progress gate every intent", %{user: user} do
      for intent <- [nil | ~w(fighter coach gym sponsor)] do
        assert %{
                 destination: :account_registration,
                 account_registration: :not_started,
                 mandatory: true
               } =
                 resolve!(user, intent)
      end

      {:ok, _} = Accounts.update_account_registration(user, %{"full_name" => "Alex Kowalski"})

      for intent <- [nil | ~w(fighter coach gym sponsor)] do
        assert %{destination: :account_registration, account_registration: :in_progress} =
                 resolve!(user, intent)
      end
    end

    test "a partial fighter profile does not bypass account registration", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, %{"city" => "Warsaw"})

      assert %{destination: :account_registration, fighter_profile: :in_progress} =
               resolve!(user, "fighter")
    end

    test "Fighter journey: not started, in progress, completed, then repeated sign-ins", %{
      user: user
    } do
      user = complete_account_registration!(user)

      assert %{destination: :role_selection, fighter_profile: :not_started} = resolve!(user)

      assert %{destination: :fighter_onboarding, reason: :fighter_onboarding_not_started} =
               resolve!(user, "fighter")

      {:ok, _} = Fighters.update_profile(user, %{"display_name" => "Alex K."})

      for intent <- [nil, "fighter"] do
        assert %{
                 destination: :fighter_onboarding,
                 reason: :fighter_onboarding_in_progress,
                 capabilities: []
               } =
                 resolve!(user, intent)
      end

      {:ok, _} = Fighters.update_profile(user, fighter_fields())
      {:ok, _} = Fighters.complete_onboarding(user)

      for _repeat <- 1..3, intent <- [nil, "fighter"] do
        assert %{
                 destination: :fighter_home,
                 fighter_profile: :completed,
                 capabilities: [:fighter]
               } =
                 resolve!(user, intent)
      end
    end

    test "account completion is followed by re-resolution with the same intent", %{user: user} do
      assert %{destination: :account_registration} = resolve!(user, "fighter")
      complete_account_registration!(user)
      assert %{destination: :fighter_onboarding} = resolve!(user, "fighter")
      assert %{destination: :role_selection} = resolve!(user)
    end

    test "Coach, Gym and Sponsor route to their entry points and create nothing", %{user: user} do
      user = complete_account_registration!(user)

      for {intent, destination} <- [
            {"coach", :coach_onboarding},
            {"gym", :gym_onboarding},
            {"sponsor", :sponsor_application}
          ] do
        assert %{destination: ^destination, capabilities: []} = resolve!(user, intent)
      end

      assert Fighters.get_profile(user) == nil
    end

    test "an explicit intent wins over unrelated Fighter progress", %{user: user} do
      user = complete_account_registration!(user)
      {:ok, _} = Fighters.update_profile(user, %{"city" => "Warsaw"})

      assert %{destination: :coach_onboarding, fighter_profile: :in_progress} =
               resolve!(user, "coach")
    end

    test "invalid intents are validation errors, never roles", %{user: user} do
      for bad <- [
            "Fighter",
            "admin",
            "FIGHTER",
            "fighter ",
            "workspace",
            ["fighter"],
            %{"a" => 1},
            1
          ] do
        assert {:error, changeset} = Entry.resolve(user, %{"intent" => bad})
        assert %{field_codes: %{"intent" => [code]}} = ChangesetErrors.details(changeset)
        assert code in ["invalid_choice", "invalid_type"]
      end

      for none <- [nil, ""] do
        assert {:ok, %{intent: nil}} = Entry.resolve(user, %{"intent" => none})
      end
    end

    test "resolution is read-only: it creates no row and changes no user", %{user: user} do
      before = snapshot(user)

      for intent <- [nil | ~w(fighter coach gym sponsor)], _ <- 1..2, do: resolve!(user, intent)

      assert snapshot(user) == before
    end
  end

  defp snapshot(user) do
    {Repo.aggregate(AccountProfile, :count), Repo.aggregate(AccountConsent, :count),
     Repo.aggregate(FighterProfile, :count), Repo.get!(User, user.id)}
  end
end
