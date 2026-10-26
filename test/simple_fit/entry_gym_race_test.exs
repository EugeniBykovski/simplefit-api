defmodule SimpleFit.EntryGymRaceTest do
  @moduledoc """
  Gym entry and context selection under true concurrency and real commits
  (SF-84), on separate database connections outside the SQL sandbox. Every
  test removes the gyms, choices, audit events, limiter rows and users it
  created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.FighterOnboardingHelpers
  import SimpleFit.GymHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.{Accounts, Entry, Gyms, Repo}
  alias SimpleFit.Accounts.User
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Gyms.{AuditEvent, Gym, StaffMembership}

  setup do
    Sandbox.mode(Repo, :auto)
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)

      gym_ids =
        Repo.all(
          from(g in Gym,
            left_join: m in StaffMembership,
            on: m.gym_id == g.id,
            where: g.created_by_user_id in ^ids or m.user_id in ^ids,
            distinct: true,
            select: g.id
          )
        )

      Repo.delete_all(from(e in AuditEvent, where: e.gym_id in ^gym_ids))
      Repo.delete_all(from(g in Gym, where: g.id in ^gym_ids))
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all("rate_limit_events")
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  defp user!(users) do
    user = registered!("entry-gym-race")
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

  defp choose(user, gym_id),
    do: Entry.record_context_choice(user, %{"context" => "gym", "gym_id" => gym_id})

  defp resolve!(user, params \\ %{}) do
    {:ok, entry} = Entry.resolve(user, params)
    entry
  end

  defp choice(user), do: Repo.get(ContextChoice, user.id)

  test "two simultaneous gym choices: one row, naming one of the two gyms", %{users: users} do
    for _ <- 1..5 do
      user = user!(users)
      gym_a = completed_gym!(user!(users))
      gym_b = completed_gym!(user!(users))
      staff!(gym_a.id, user, :manager)
      staff!(gym_b.id, user, :coach)

      results = concurrently([fn -> choose(user, gym_a.id) end, fn -> choose(user, gym_b.id) end])

      assert Enum.all?(results, &match?({:ok, %ContextChoice{}}, &1))
      assert choice(user).gym_id in [gym_a.id, gym_b.id]
      assert resolve!(user).gym_id == choice(user).gym_id
    end
  end

  test "a choice racing the revocation: never a valid entry into the revoked gym", %{users: users} do
    for _ <- 1..8 do
      owner = user!(users)
      user = user!(users)
      gym = completed_gym!(owner)
      m = staff!(gym.id, user, :front_desk)

      [chosen, revoked] =
        concurrently([
          fn -> choose(user, gym.id) end,
          fn -> Gyms.revoke_staff_membership(owner, gym.id, m.id) end
        ])

      assert {:ok, %StaffMembership{status: :ended}} = revoked

      case chosen do
        # The choice committed first; the revocation then made it stale.
        {:ok, _} -> assert choice(user).gym_id == gym.id
        # The revocation committed first: nothing was recorded.
        {:error, :not_found} -> assert choice(user) == nil
      end

      entry = resolve!(user)
      assert entry.gym_id == nil
      refute :gym_workspace in entry.capabilities
      assert entry.gym_workspaces == []
    end
  end

  test "a choice racing an ownership transfer away from the chooser", %{users: users} do
    for _ <- 1..6 do
      owner = user!(users)
      gym = completed_gym!(owner)
      target = staff!(gym.id, user!(users), :manager)

      [chosen, transferred] =
        concurrently([
          fn -> choose(owner, gym.id) end,
          fn -> Gyms.transfer_ownership(owner, gym.id, target.id, :leave) end
        ])

      assert {:ok, _} = transferred
      assert match?({:ok, _}, chosen) or chosen == {:error, :not_found}

      # The former owner has no workspace there, whatever the order.
      entry = resolve!(owner, %{"intent" => "gym"})
      assert entry.destination == :gym_onboarding
      assert entry.gym_workspaces == []
    end
  end

  test "registration completion racing resolution: each answer is one consistent state", %{
    users: users
  } do
    for _ <- 1..5 do
      {:ok, user} = Accounts.register_user(:google, "race-reg-#{Ecto.UUID.generate()}")
      Agent.update(users, &[user.id | &1])

      [resolved, _completed] =
        concurrently([
          fn -> Entry.resolve(user, %{"intent" => "gym"}) end,
          fn -> complete_account_registration!(user) end
        ])

      assert {:ok, %{destination: destination}} = resolved
      assert destination in [:account_registration, :gym_onboarding]
      assert resolve!(user, %{"intent" => "gym"}).destination == :gym_onboarding
      assert gyms_created_by(user) == 0
    end
  end

  test "switching between Fighter, Coach and a gym, and back", %{users: users} do
    user = user!(users)
    complete_fighter_onboarding!(user)
    SimpleFit.CoachingHelpers.complete_coach!(user, "Coach Ola")
    gym = completed_gym!(user)

    for {params, expected} <- [
          {%{"context" => "fighter"}, {:fighter_home, nil}},
          {%{"context" => "gym", "gym_id" => gym.id}, {:gym_home, gym.id}},
          {%{"context" => "coach"}, {:coach_home, nil}},
          {%{"context" => "gym", "gym_id" => gym.id}, {:gym_home, gym.id}}
        ] do
      {:ok, _} = Entry.record_context_choice(user, params)
      entry = resolve!(user)
      assert {entry.destination, entry.gym_id} == expected
    end
  end

  test "a remembered gym deleted later takes the choice with it", %{users: users} do
    user = user!(users)
    gym = completed_gym!(user)
    {:ok, _} = choose(user, gym.id)

    Repo.delete_all(from(e in AuditEvent, where: e.gym_id == ^gym.id))
    Repo.delete_all(from(g in Gym, where: g.id == ^gym.id))

    assert choice(user) == nil
    assert resolve!(user).destination == :role_selection
  end
end
