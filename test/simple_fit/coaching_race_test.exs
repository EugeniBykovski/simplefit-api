defmodule SimpleFit.CoachingRaceTest do
  @moduledoc """
  Coach–Fighter relationships under true concurrency, on separate database
  connections (outside the SQL sandbox), so the partial unique index, the
  triggers and row locks are exercised for real (ADR 0021). Rows are
  committed, so every test removes the users it created (profiles and
  relationships cascade).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.CoachingHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.{Accounts, Coaches, Coaching, Repo}
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaching.{Activation, Relationship}

  setup do
    Sandbox.mode(Repo, :auto)
    configure_sharing()
    # Not linked to the test process, which has exited when on_exit runs.
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  defp track(user, users) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp coach!(users, name \\ "Coach Marek"), do: coach_user!(name) |> track(users)
  defp fighter!(users), do: fighter_user!() |> track(users)

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(15_000)

  defp pair_rows(coach, fighter, status) do
    coach_profile = Coaches.get_profile(coach).id
    fighter_profile = SimpleFit.Fighters.get_profile(fighter).id

    Repo.aggregate(
      from(r in Relationship,
        where:
          r.coach_profile_id == ^coach_profile and r.fighter_profile_id == ^fighter_profile and
            r.status == ^status
      ),
      :count
    )
  end

  test "simultaneous acceptances of one pair create exactly one active relationship", %{
    users: users
  } do
    coach = coach!(users)
    fighter = fighter!(users)
    coach_profile = Coaches.get_profile(coach).id

    results =
      concurrently(
        for _ <- 1..10, do: fn -> Activation.activate(coach_profile, fighter, version()) end
      )

    assert Enum.all?(results, &match?({:ok, %Relationship{}, _}, &1))
    assert results |> Enum.map(fn {:ok, r, _} -> r.id end) |> Enum.uniq() |> length() == 1
    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert pair_rows(coach, fighter, :active) == 1
  end

  test "different coaches connect to one fighter independently and in parallel", %{users: users} do
    fighter = fighter!(users)
    coaches = for i <- 1..6, do: coach!(users, "Coach #{i}")

    results =
      concurrently(
        for coach <- coaches do
          fn -> Activation.activate(Coaches.get_profile(coach).id, fighter, version()) end
        end
      )

    assert Enum.all?(results, &match?({:ok, _, :created}, &1))
    {:ok, page} = Coaching.list_fighter_relationships(fighter, %{})
    assert length(page.entries) == 6
  end

  test "the coach and the fighter ending at once: one end, both succeed", %{users: users} do
    for _ <- 1..10 do
      coach = coach!(users)
      fighter = fighter!(users)
      r = activate!(coach, fighter)

      results =
        concurrently([
          fn -> Coaching.end_relationship(coach, :coach, r.id) end,
          fn -> Coaching.end_relationship(fighter, :fighter, r.id) end,
          fn -> Coaching.end_relationship(coach, :coach, r.id) end
        ])

      assert results == [:ok, :ok, :ok]
      ended = Repo.get!(Relationship, r.id)
      assert ended.status == :ended and ended.ended_by in [:coach, :fighter]
      assert pair_rows(coach, fighter, :active) == 0
    end
  end

  test "an acceptance racing an end never leaves two active relationships or a revived one", %{
    users: users
  } do
    for _ <- 1..10 do
      coach = coach!(users)
      fighter = fighter!(users)
      r = activate!(coach, fighter)
      coach_profile = Coaches.get_profile(coach).id

      [ended, accepted] =
        concurrently([
          fn -> Coaching.end_relationship(fighter, :fighter, r.id) end,
          fn -> Activation.activate(coach_profile, fighter, version()) end
        ])

      assert ended == :ok
      assert {:ok, %Relationship{} = result, outcome} = accepted
      # The original relationship is ended for good.
      assert Repo.get!(Relationship, r.id).status == :ended
      assert pair_rows(coach, fighter, :active) <= 1

      case outcome do
        # The acceptance saw the still-active row: it is now ended.
        :existing -> assert result.id == r.id
        # It ran after the end: a new relationship (a reconnection).
        :created -> refute result.id == r.id
      end
    end
  end

  test "activation never crashes when the pair's active relationship ends under it", %{
    users: users
  } do
    # SF-57 found this: an insert that conflicted with the active row could
    # find no active row afterwards when an end committed in between.
    for _ <- 1..40 do
      coach = coach!(users)
      fighter = fighter!(users)
      r = activate!(coach, fighter)
      coach_profile = Coaches.get_profile(coach).id

      results =
        concurrently([
          fn -> Coaching.end_relationship(fighter, :fighter, r.id) end,
          fn -> Activation.activate(coach_profile, fighter, version()) end,
          fn -> Activation.activate(coach_profile, fighter, version()) end
        ])

      assert [:ok, {:ok, %Relationship{}, _}, {:ok, %Relationship{}, _}] = results
      assert pair_rows(coach, fighter, :active) <= 1
    end
  end

  test "once an end is confirmed, every later read is denied", %{users: users} do
    coach = coach!(users)
    fighter = fighter!(users)
    r = activate!(coach, fighter)

    reader =
      Task.async(fn ->
        Stream.repeatedly(fn -> Coaching.get_coach_relationship(coach, r.id) end)
        |> Enum.take(200)
      end)

    :ok = Coaching.end_relationship(fighter, :fighter, r.id)
    confirmed_at = System.monotonic_time()
    Task.await(reader, 15_000)

    # Any read issued after the confirmed end is not_found.
    after_end = for _ <- 1..20, do: Coaching.get_coach_relationship(coach, r.id)
    assert Enum.all?(after_end, &(&1 == {:error, :not_found}))
    assert System.monotonic_time() >= confirmed_at
  end

  test "a failed activation leaves nothing behind", %{users: users} do
    both = coach!(users) |> complete_fighter_onboarding!()
    fighter = fighter!(users)
    coach = coach!(users)

    results =
      concurrently([
        fn -> Activation.activate(Coaches.get_profile(both).id, both, version()) end,
        fn -> Activation.activate(Coaches.get_profile(coach).id, fighter, "not-offered") end
      ])

    assert results == [{:error, :self_coaching}, {:error, :disclosure_not_offered}]
    assert pair_rows(coach, fighter, :active) == 0
    assert pair_rows(both, both, :active) == 0
  end

  test "deleting an account while relationships are read or ended stays consistent", %{
    users: users
  } do
    coach = coach!(users)
    fighter = fighter!(users)
    r = activate!(coach, fighter)

    concurrently([
      fn -> Repo.delete(Repo.get!(Accounts.User, fighter.id)) end,
      fn -> Coaching.end_relationship(coach, :coach, r.id) end,
      fn -> Coaching.get_coach_relationship(coach, r.id) end
    ])

    assert Repo.get(Relationship, r.id) == nil
    assert {:error, :not_found} = Coaching.get_coach_relationship(coach, r.id)
  end
end
