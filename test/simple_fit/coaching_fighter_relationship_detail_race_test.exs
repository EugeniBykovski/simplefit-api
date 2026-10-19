defmodule SimpleFit.CoachingFighterRelationshipDetailRaceTest do
  @moduledoc """
  Reading one relationship (SF-74) while it changes, on separate database
  connections outside the SQL sandbox. A read is one statement under READ
  COMMITTED: it sees the last committed row, so a read racing an end returns
  either the whole active entry or the whole ended stub, never a mix, and
  every read after the end commits sees the stub. A read racing a deletion
  returns the entry or `:not_found`. Rows are committed, so every test
  removes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.CoachingHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaching, Fighters, Repo}

  setup do
    Sandbox.mode(Repo, :auto)
    configure_sharing()
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

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(15_000)

  defp pair(users) do
    coach = coach_user!("Coach Marek") |> track(users)
    fighter = fighter_user!() |> track(users)
    {coach, fighter, activate!(coach, fighter)}
  end

  # A whole entry of one state: active with the live coach, or ended with the
  # snapshot; never a mix.
  defp whole!({:ok, %{status: :active} = e}) do
    assert e.coach == %{display_name: "Coach Marek", brand_name: "Marek Boxing"}
    assert e.ended_at == nil and e.ended_by == nil and e.coach_display_name_at_end == nil
    assert length(e.disclosed_fields) == 7
    :active
  end

  defp whole!({:ok, %{status: :ended} = e}) do
    assert e.coach == nil and e.disclosed_fields == []
    assert %DateTime{} = e.ended_at
    assert e.ended_by in [:coach, :fighter]
    assert e.coach_display_name_at_end == "Coach Marek"
    :ended
  end

  for side <- [:coach, :fighter] do
    test "reads racing the #{side}'s end: whole entries, ended afterwards", %{users: users} do
      for _ <- 1..5 do
        {coach, fighter, r} = pair(users)
        ender = if unquote(side) == :coach, do: coach, else: fighter

        results =
          concurrently(
            [fn -> Coaching.end_relationship(ender, unquote(side), r.id) end] ++
              for(_ <- 1..6, do: fn -> Coaching.get_fighter_relationship(fighter, r.id) end)
          )

        [ended | reads] = results
        assert ended == :ok
        assert Enum.all?(Enum.map(reads, &whole!/1), &(&1 in [:active, :ended]))

        assert whole!(Coaching.get_fighter_relationship(fighter, r.id)) == :ended

        assert {:ok, %{ended_by: unquote(side)}} =
                 Coaching.get_fighter_relationship(fighter, r.id)
      end
    end
  end

  test "reads racing the list and each other agree", %{users: users} do
    {_coach, fighter, r} = pair(users)

    results =
      concurrently(
        for(_ <- 1..4, do: fn -> Coaching.get_fighter_relationship(fighter, r.id) end) ++
          for(_ <- 1..4, do: fn -> Coaching.list_fighter_relationships(fighter, %{}) end)
      )

    {reads, lists} = Enum.split(results, 4)
    entries = Enum.map(reads, fn {:ok, e} -> e end)
    assert Enum.uniq(entries) |> length() == 1
    for {:ok, %{entries: [listed]}} <- lists, do: assert(listed == hd(entries))
  end

  test "reads racing the deletion of the coach or the fighter profile: entry or not_found", %{
    users: users
  } do
    for target <- [:coach, :fighter_profile] do
      {coach, fighter, r} = pair(users)

      delete = fn ->
        case target do
          :coach -> Repo.delete_all(from(u in User, where: u.id == ^coach.id))
          :fighter_profile -> Repo.delete!(Fighters.get_profile(fighter))
        end
      end

      [_deleted | reads] =
        concurrently(
          [delete] ++
            for(_ <- 1..6, do: fn -> Coaching.get_fighter_relationship(fighter, r.id) end)
        )

      for read <- reads do
        assert read == {:error, :not_found} or whole!(read) == :active
      end

      assert Coaching.get_fighter_relationship(fighter, r.id) == {:error, :not_found}
    end
  end
end
