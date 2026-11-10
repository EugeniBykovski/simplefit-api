defmodule SimpleFit.OverviewRaceTest do
  @moduledoc """
  SF-121 under real commits, outside the SQL sandbox: the overview reads its counts
  in one REPEATABLE READ snapshot while accounts are being created concurrently, so
  the counts agree with each other. `not_started` is derived (`users - profiles`);
  read across two moments it could go negative when a user and its profile commit
  between the two counts. Each test deletes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.Operators.Overview
  alias SimpleFit.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    previous = Application.get_env(:simple_fit, Overview)
    Application.put_env(:simple_fit, Overview, snapshot: true)
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Application.put_env(:simple_fit, Overview, previous)
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all("auth_rate_limits")
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  test "counts read while accounts are created stay consistent with each other", %{users: users} do
    dashboard = MapSet.new(["platform.dashboard.read"])

    writer =
      Task.async(fn ->
        for n <- 1..40 do
          user = registered!("race-#{n}")
          Agent.update(users, &[user.id | &1])
        end
      end)

    readers =
      for _ <- 1..4 do
        Task.async(fn ->
          for _ <- 1..25 do
            accounts = Enum.find(Overview.build(dashboard, "7d").metrics, &(&1.id == :accounts))
            breakdown = Map.new(accounts.breakdown)
            {accounts.value, breakdown.in_progress, breakdown.not_started}
          end
        end)
      end

    Task.await(writer, 30_000)
    reads = Enum.flat_map(readers, &Task.await(&1, 30_000))

    assert length(reads) == 100

    assert Enum.all?(reads, fn {complete, in_progress, not_started} ->
             complete >= 0 and in_progress >= 0 and not_started >= 0
           end)

    # Totals only grow while nothing is deleted: each read is a real moment.
    final = Enum.find(Overview.build(dashboard, "7d").metrics, &(&1.id == :accounts)).value
    assert Enum.all?(reads, fn {complete, _, _} -> complete <= final end)
  end

  test "the snapshot is read only: nothing can be written through it" do
    assert_raise Postgrex.Error, ~r/read-only transaction/, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")

        Repo.query!(
          "INSERT INTO users (id, inserted_at, updated_at) VALUES (gen_random_uuid(), now(), now())"
        )
      end)
    end
  end

  test "inside the snapshot a concurrent commit isn't seen; without it, it is", %{users: users} do
    count = fn -> Repo.aggregate(User, :count) end

    commit_one = fn ->
      Task.async(fn ->
        user = registered!("between")
        Agent.update(users, &[user.id | &1])
      end)
      |> Task.await(15_000)
    end

    {before, after_commit} =
      Overview.snapshot(fn ->
        first = count.()
        commit_one.()
        {first, count.()}
      end)

    assert after_commit == before

    # The negative control: the same sequence outside a snapshot sees the commit.
    Application.put_env(:simple_fit, Overview, snapshot: false)

    {before, after_commit} =
      Overview.snapshot(fn ->
        first = count.()
        commit_one.()
        {first, count.()}
      end)

    assert after_commit == before + 1
  end
end
