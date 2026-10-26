defmodule SimpleFit.EntryGymTest do
  @moduledoc """
  Gym registration intent and gym workspace entry (SF-84; ADR 0017 SF-84
  amendment, ADR 0026): the pure decision rules with gym facts, and
  resolution over real persisted gyms and staff memberships. Concurrency is
  in `SimpleFit.EntryGymRaceTest`.
  """

  use SimpleFit.DataCase, async: true

  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.CoachingHelpers, only: [complete_coach!: 2]
  import SimpleFit.FighterOnboardingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Entry, Gyms}
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Gyms.{Gym, StaffMembership}

  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"

  defp gyms(completed, single \\ nil, draft \\ nil),
    do: %{completed_count: completed, single_completed_gym_id: single, open_draft_gym_id: draft}

  defp decide(facts) do
    %{intent: nil, account_registration: :complete, fighter_profile: :not_started}
    |> Map.merge(Map.new(facts))
    |> Entry.decide()
    |> then(&{&1.destination, &1.reason, &1.gym_id})
  end

  describe "decide/1 with gym facts" do
    test "a Gym intent resolves by real gym workspaces and never creates anything" do
      assert decide(intent: :gym) == {:gym_onboarding, :gym_setup_not_started, nil}

      assert decide(intent: :gym, gyms: gyms(0, nil, @a)) ==
               {:gym_onboarding, :gym_setup_in_progress, @a}

      assert decide(intent: :gym, gyms: gyms(1, @a)) == {:gym_home, :gym_workspace_completed, @a}
      assert decide(intent: :gym, gyms: gyms(2)) == {:gym_selection, :gym_choice_required, nil}

      assert decide(intent: :gym, gyms: gyms(2), last_gym_id: @b) ==
               {:gym_home, :last_context, @b}

      # A completed gym and a draft: both are exposed for an explicit choice.
      assert decide(intent: :gym, gyms: gyms(1, @a, @b)) ==
               {:gym_selection, :gym_choice_required, nil}

      assert decide(intent: :gym, gyms: gyms(1, @a, @b), last_gym_id: @a) ==
               {:gym_selection, :gym_choice_required, nil}
    end

    test "account registration comes first, whatever the gyms" do
      for account <- [:not_started, :in_progress], intent <- [nil, :gym] do
        assert decide(account_registration: account, intent: intent, gyms: gyms(2, nil, @a)) ==
                 {:account_registration, :account_registration_incomplete, nil}
      end
    end

    test "Fighter and Coach intents are unchanged by gyms" do
      assert decide(intent: :fighter, fighter_profile: :completed, gyms: gyms(1, @a)) ==
               {:fighter_home, :fighter_onboarding_completed, nil}

      assert decide(intent: :coach, coach_profile: :in_progress, gyms: gyms(1, @a)) ==
               {:coach_onboarding, :coach_onboarding_in_progress, nil}
    end

    test "defaults count each completed gym as a context; a draft is a journey in progress" do
      # Only the draft the user owns: resume it.
      assert decide(gyms: gyms(0, nil, @a)) == {:gym_onboarding, :gym_setup_in_progress, @a}

      # A draft next to a Fighter onboarding in progress: choose.
      assert decide(fighter_profile: :in_progress, gyms: gyms(0, nil, @a)) ==
               {:context_selection, :multiple_roles_in_progress, nil}

      # A completed Fighter profile keeps its home; the draft stays reachable.
      assert decide(fighter_profile: :completed, gyms: gyms(0, nil, @a)) ==
               {:fighter_home, :fighter_onboarding_completed, nil}

      # One completed gym and nothing else: its home.
      assert decide(gyms: gyms(1, @a)) == {:gym_home, :gym_workspace_completed, @a}

      # Fighter and a gym: the remembered choice while valid, otherwise choose.
      assert decide(fighter_profile: :completed, gyms: gyms(1, @a)) ==
               {:context_selection, :context_choice_required, nil}

      assert decide(fighter_profile: :completed, gyms: gyms(1, @a), last_context: :fighter) ==
               {:fighter_home, :last_context, nil}

      assert decide(
               fighter_profile: :completed,
               gyms: gyms(1, @a),
               last_context: :gym,
               last_gym_id: @a
             ) == {:gym_home, :last_context, @a}

      # A remembered gym that is no longer valid is ignored (no last_gym_id).
      assert decide(fighter_profile: :completed, gyms: gyms(1, @a), last_context: :gym) ==
               {:context_selection, :context_choice_required, nil}
    end

    test "a requested gym context opens a completed gym only" do
      completed = %{gym_id: @a, setup_status: :completed}
      draft = %{gym_id: @a, setup_status: :draft}

      assert decide(context: :gym, requested_gym: completed, fighter_profile: :completed) ==
               {:gym_home, :requested_context, @a}

      # A draft or an unusable gym is ignored, exactly like an incomplete profile.
      assert decide(context: :gym, requested_gym: draft, fighter_profile: :completed) ==
               {:fighter_home, :fighter_onboarding_completed, nil}

      assert decide(context: :gym, requested_gym: nil, fighter_profile: :completed) ==
               {:fighter_home, :fighter_onboarding_completed, nil}
    end

    test "GYM_WORKSPACE comes only from a completed gym workspace" do
      base = %{intent: nil, account_registration: :complete, fighter_profile: :completed}

      assert Entry.decide(Map.put(base, :gyms, gyms(0, nil, @a))).capabilities == [:fighter]

      assert Entry.decide(Map.put(base, :gyms, gyms(1, @a))).capabilities == [
               :fighter,
               :gym_workspace
             ]

      assert Entry.decide(%{
               intent: :gym,
               account_registration: :complete,
               fighter_profile: :not_started
             }).capabilities ==
               []
    end
  end

  describe "resolve/2 over persisted gyms" do
    defp resolve!(user, params \\ %{}) do
      {:ok, entry} = Entry.resolve(user, params)
      entry
    end

    defp gym_rows(user),
      do: Repo.aggregate(from(m in StaffMembership, where: m.user_id == ^user.id), :count)

    test "Gym intent before account registration: registration first, nothing created" do
      {:ok, user} = Accounts.register_user(:google, "entry-gym-#{System.unique_integer()}")

      assert %{destination: :account_registration, intent: :gym, gym_workspaces: []} =
               resolve!(user, %{"intent" => "gym"})

      assert gym_rows(user) == 0
    end

    test "Gym intent without a gym starts setup and never creates a gym, however often" do
      user = registered!()

      for _ <- 1..5 do
        assert %{destination: :gym_onboarding, reason: :gym_setup_not_started, gym_id: nil} =
                 resolve!(user, %{"intent" => "gym"})
      end

      assert gym_rows(user) == 0
      assert gyms_created_by(user) == 0
      assert Repo.aggregate(ContextChoice, :count) == 0
    end

    test "the owner's draft is resumed, with and without the intent" do
      user = registered!()
      draft = draft_gym!(user)

      for params <- [%{"intent" => "gym"}, %{}] do
        entry = resolve!(user, params)

        assert {entry.destination, entry.reason, entry.gym_id} ==
                 {:gym_onboarding, :gym_setup_in_progress, draft.id}

        assert entry.capabilities == []

        assert [
                 %{
                   gym_id: id,
                   setup_status: :draft,
                   role: :owner,
                   available_actions: [:continue_setup]
                 }
               ] =
                 entry.gym_workspaces

        assert id == draft.id
      end
    end

    test "one completed gym is entered; GYM_WORKSPACE appears" do
      user = registered!()
      gym = completed_gym!(user)

      entry = resolve!(user, %{"intent" => "gym"})
      assert {entry.destination, entry.gym_id} == {:gym_home, gym.id}
      assert entry.capabilities == [:gym_workspace]
      assert [%{available_actions: [:enter], selected: false}] = entry.gym_workspaces
      assert resolve!(user).destination == :gym_home
    end

    test "staff at two gyms: chooser, explicit choice, then the remembered gym" do
      user = registered!()
      gym_a = completed_gym!(registered!())
      gym_b = completed_gym!(registered!())
      staff!(gym_a.id, user, :manager)
      staff!(gym_b.id, user, :front_desk)

      entry = resolve!(user, %{"intent" => "gym"})
      assert {entry.destination, entry.reason} == {:gym_selection, :gym_choice_required}
      assert entry.gym_workspace_count == 2

      assert entry.gym_workspaces |> Enum.map(&{&1.gym_id, &1.role}) |> Enum.sort() ==
               Enum.sort([{gym_a.id, :manager}, {gym_b.id, :front_desk}])

      assert resolve!(user).destination == :context_selection

      assert {:ok, %ContextChoice{context: :gym}} =
               Entry.record_context_choice(user, %{"context" => "gym", "gym_id" => gym_b.id})

      for params <- [%{}, %{"intent" => "gym"}] do
        entry = resolve!(user, params)

        assert {entry.destination, entry.reason, entry.gym_id} ==
                 {:gym_home, :last_context, gym_b.id}

        assert Enum.find(entry.gym_workspaces, & &1.selected).gym_id == gym_b.id
      end

      # An explicit gym context (another tab) opens the other gym without changing the choice.
      assert resolve!(user, %{"context" => "gym", "gym_id" => gym_a.id}).gym_id == gym_a.id
      assert Repo.get!(ContextChoice, user.id).gym_id == gym_b.id
    end

    test "a draft and a completed gym are both exposed with their real setup states" do
      user = registered!()
      completed = completed_gym!(registered!())
      staff!(completed.id, user, :coach)
      draft = draft_gym!(user)

      entry = resolve!(user, %{"intent" => "gym"})
      assert entry.destination == :gym_selection

      assert [first, second] = entry.gym_workspaces
      # The viewer's own draft comes first.
      assert {first.gym_id, first.setup_status, first.available_actions} ==
               {draft.id, :draft, [:continue_setup]}

      assert {second.gym_id, second.setup_status, second.available_actions} ==
               {completed.id, :completed, [:enter]}
    end

    test "Fighter + Coach + Gym owner keeps every real capability" do
      user = registered!()
      complete_fighter_onboarding!(user)
      complete_coach!(user, "Coach Ola")
      completed_gym!(user)

      entry = resolve!(user)
      assert entry.capabilities == [:fighter, :coach, :gym_workspace]
      assert entry.destination == :context_selection

      assert resolve!(user, %{"intent" => "fighter"}).destination == :fighter_home
      assert resolve!(user, %{"intent" => "coach"}).destination == :coach_home
      assert resolve!(user, %{"intent" => "gym"}).destination == :gym_home

      {:ok, _} = Entry.record_context_choice(user, %{"context" => "coach"})
      assert resolve!(user).destination == :coach_home
    end

    test "an existing Fighter with a Gym intent stays a Fighter; no gym is created" do
      user = registered!()
      complete_fighter_onboarding!(user)

      assert %{destination: :gym_onboarding, capabilities: [:fighter]} =
               resolve!(user, %{"intent" => "gym"})

      assert resolve!(user).destination == :fighter_home
      assert gym_rows(user) == 0
    end

    test "a revoked membership disappears from the next resolution and its choice is ignored" do
      user = registered!()
      owner = registered!()
      gym = completed_gym!(owner)
      m = staff!(gym.id, user, :coach)
      complete_fighter_onboarding!(user)
      {:ok, _} = Entry.record_context_choice(user, %{"context" => "gym", "gym_id" => gym.id})
      assert resolve!(user).gym_id == gym.id

      {:ok, _} = Gyms.revoke_staff_membership(owner, gym.id, m.id)

      entry = resolve!(user)
      assert {entry.destination, entry.gym_id} == {:fighter_home, nil}
      assert entry.capabilities == [:fighter]
      assert entry.gym_workspaces == [] and entry.gym_workspace_count == 0

      assert resolve!(user, %{"context" => "gym", "gym_id" => gym.id}).destination ==
               :fighter_home
    end

    test "a role change is reflected on the next resolution" do
      owner = registered!()
      user = registered!()
      gym = completed_gym!(owner)
      m = staff!(gym.id, user, :coach)
      assert [%{role: :coach}] = resolve!(user).gym_workspaces

      {:ok, _} = Gyms.transfer_ownership(owner, gym.id, m.id, :leave)
      assert [%{role: :owner}] = resolve!(user).gym_workspaces
      assert resolve!(owner).gym_workspaces == []
    end

    test "foreign, unknown and draft gyms cannot be chosen or opened, and are never reported" do
      user = registered!()
      complete_fighter_onboarding!(user)
      foreign = completed_gym!(registered!())
      own_draft = draft_gym!(user)

      for gym_id <- [foreign.id, Ecto.UUID.generate()] do
        assert {:error, :not_found} =
                 Entry.record_context_choice(user, %{"context" => "gym", "gym_id" => gym_id})

        entry = resolve!(user, %{"context" => "gym", "gym_id" => gym_id})
        assert {entry.destination, entry.context, entry.gym_id} == {:fighter_home, nil, nil}
        refute Enum.any?(entry.gym_workspaces, &(&1.gym_id == gym_id))
      end

      assert {:error, {:conflict, %{setup_status: "draft"}}} =
               Entry.record_context_choice(user, %{"context" => "gym", "gym_id" => own_draft.id})

      assert Repo.aggregate(ContextChoice, :count) == 0
    end

    test "a coach or fighter profile alone grants no gym workspace" do
      user = registered!()
      complete_fighter_onboarding!(user)
      complete_coach!(user, "Coach Ola")
      completed_gym!(registered!())

      entry = resolve!(user)
      refute :gym_workspace in entry.capabilities
      assert entry.gym_workspaces == [] and entry.gym_workspace_count == 0
    end

    test "another account never sees a user's gyms or choice" do
      a = registered!()
      b = registered!()
      gym = completed_gym!(a)
      {:ok, _} = Entry.record_context_choice(a, %{"context" => "gym", "gym_id" => gym.id})

      entry = resolve!(b)
      assert entry.gym_workspaces == [] and entry.gym_id == nil
      assert entry.destination == :role_selection
    end

    test "chooser entries carry only the viewer's facts and the gym's name" do
      user = registered!()
      completed_gym!(user, %{"name" => "Simple Boxing Gym"})

      [entry] = resolve!(user).gym_workspaces

      assert entry |> Map.keys() |> Enum.sort() ==
               ~w(available_actions gym_id name role selected setup_status)a
    end

    test "the chooser is bounded; the count is complete" do
      user = registered!()

      for _ <- 1..27 do
        staff!(completed_gym!(registered!()).id, user, :coach)
      end

      entry = resolve!(user, %{"intent" => "gym"})
      assert length(entry.gym_workspaces) == 25
      assert entry.gym_workspace_count == 27
      assert entry.destination == :gym_selection
    end

    test "users from every sign-in method resolve the same Gym journey" do
      for {provider, subject} <- [
            {:email, "gym-intent-#{System.unique_integer([:positive])}@example.com"},
            {:google, "gym-google-#{System.unique_integer([:positive])}"},
            {:apple, "gym-apple-#{System.unique_integer([:positive])}"}
          ] do
        {:ok, user} = Accounts.register_user(provider, subject)
        assert resolve!(user, %{"intent" => "gym"}).destination == :account_registration

        complete_account_registration!(user)

        assert %{destination: :gym_onboarding, reason: :gym_setup_not_started} =
                 resolve!(user, %{"intent" => "gym"})

        assert Repo.aggregate(from(g in Gym, where: g.created_by_user_id == ^user.id), :count) ==
                 0
      end
    end
  end
end
