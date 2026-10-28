defmodule SimpleFit.GymFirstRunRaceTest do
  @moduledoc """
  The gym first run under true concurrency and real commits (SF-90), on
  separate database connections outside the SQL sandbox: the unique
  `(gym_id, user_id)` row, the first-run row lock, the final-outcome
  trigger and the shared gym-row lock against transfer, revocation, setup
  writes and discard. Each scenario repeats to catch lock-order defects.
  Every test removes the gyms, audit events, limiter rows and users it
  created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, Gym, GymFirstRun, StaffMembership}

  @rounds 8

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

  defp user!(ctx) do
    user = registered!("gym-first-run-race")
    Agent.update(ctx.users, &[user.id | &1])
    user
  end

  defp owned!(ctx) do
    owner = user!(ctx)
    {owner, completed_gym!(owner)}
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

  defp act(user, gym_id, action),
    do: fn -> Gyms.first_run_transition(user, gym_id, action, %{}) end

  defp rows(gym_id), do: Repo.all(from(r in GymFirstRun, where: r.gym_id == ^gym_id))

  defp events(gym_id),
    do:
      Repo.all(
        from(e in AuditEvent,
          where:
            e.gym_id == ^gym_id and e.event_type in [:first_run_completed, :first_run_dismissed],
          select: e.event_type
        )
      )

  test "simultaneous first starts: one row, one start time for everyone", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)

      results = concurrently(for _ <- 1..4, do: act(owner, gym.id, :start))

      assert [%GymFirstRun{started_at: started}] = rows(gym.id)
      assert Enum.all?(results, &match?({:ok, %{status: :in_progress, started_at: ^started}}, &1))
      assert events(gym.id) == []
    end
  end

  test "two devices completing at once: one completion, one audit event, the same answer", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)

      [a, b] = concurrently([act(owner, gym.id, :complete), act(owner, gym.id, :complete)])

      assert {:ok, %{status: :completed} = state} = a
      assert b == {:ok, state}
      assert [%GymFirstRun{completed_at: %DateTime{}}] = rows(gym.id)
      assert events(gym.id) == [:first_run_completed]
    end
  end

  test "completion racing skip, started or not: exactly one terminal outcome", ctx do
    for started? <- [false, true], _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      if started?, do: {:ok, _} = act(owner, gym.id, :start).()

      [completed, dismissed] =
        concurrently([act(owner, gym.id, :complete), act(owner, gym.id, :dismiss)])

      assert [row] = rows(gym.id)

      case row do
        %GymFirstRun{completed_at: %DateTime{}, dismissed_at: nil} ->
          assert {:ok, %{status: :completed}} = completed
          assert dismissed == {:error, {:conflict, %{first_run: "completed"}}}
          assert events(gym.id) == [:first_run_completed]

        %GymFirstRun{dismissed_at: %DateTime{}, completed_at: nil} ->
          assert {:ok, %{status: :dismissed}} = dismissed
          assert completed == {:error, {:conflict, %{first_run: "dismissed"}}}
          assert events(gym.id) == [:first_run_dismissed]
      end
    end
  end

  test "a burst of mixed transitions from several clients settles on one coherent state", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)

      actions =
        Enum.shuffle(
          List.duplicate(:start, 3) ++ List.duplicate(:complete, 3) ++ [:dismiss, :dismiss]
        )

      results = concurrently(Enum.map(actions, &act(owner, gym.id, &1)))

      assert [row] = rows(gym.id)
      outcome = if row.completed_at, do: :completed, else: :dismissed
      assert {row.completed_at != nil, row.dismissed_at != nil} in [{true, false}, {false, true}]
      assert length(events(gym.id)) == 1

      # Every success after the outcome reports that outcome; every refusal names it.
      for result <- results do
        case result do
          {:ok, %{status: status}} -> assert status in [:in_progress, outcome]
          {:error, {:conflict, %{first_run: kept}}} -> assert kept == Atom.to_string(outcome)
        end
      end
    end
  end

  test "completion racing an ownership transfer: never committed for a non-owner", ctx do
    for previous <- [:stay_as_manager, :leave], _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      heir = user!(ctx)
      target = staff!(gym.id, heir, :manager)

      [completed, transferred] =
        concurrently([
          act(owner, gym.id, :complete),
          fn -> Gyms.transfer_ownership(owner, gym.id, target.id, previous) end
        ])

      assert {:ok, _} = transferred

      case completed do
        {:ok, %{status: :completed}} ->
          assert [%GymFirstRun{user_id: user_id}] = rows(gym.id)
          assert user_id == owner.id
          assert events(gym.id) == [:first_run_completed]

        {:error, reason} ->
          assert reason == if(previous == :leave, do: :not_found, else: :forbidden)
          assert rows(gym.id) == [] and events(gym.id) == []
      end

      assert [_] = active_owners(gym.id)
    end
  end

  test "a read racing an ownership transfer answers for one side of it", ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      heir = user!(ctx)
      target = staff!(gym.id, heir, :manager)

      [read, {:ok, _}] =
        concurrently([
          fn -> Gyms.get_first_run(owner, gym.id) end,
          fn -> Gyms.transfer_ownership(owner, gym.id, target.id, :leave) end
        ])

      assert match?({:ok, %{status: :not_started}}, read) or read == {:error, :not_found}
    end
  end

  test "a staff revocation, a setup write and a first-run transition at one gym never deadlock",
       ctx do
    for _ <- 1..@rounds do
      {owner, gym} = owned!(ctx)
      coach = user!(ctx)
      membership = staff!(gym.id, coach, :coach)
      before = Repo.get!(Gym, gym.id)

      [first_run, revoked, saved] =
        concurrently([
          act(owner, gym.id, :complete),
          fn -> Gyms.revoke_staff_membership(owner, gym.id, membership.id) end,
          fn -> save_setup(owner, gym.id, %{"tagline" => "Open early"}) end
        ])

      assert {:ok, %{status: :completed}} = first_run
      assert {:ok, %StaffMembership{status: :ended}} = revoked
      assert {:ok, %{tagline: "Open early"}} = saved

      # The first run moved nothing on the gym but what the setup write did.
      after_gym = Repo.get!(Gym, gym.id)
      assert after_gym.setup_status == before.setup_status
      assert after_gym.revision == before.revision + 1
    end
  end

  test "a draft being completed or discarded never gets a first run early", ctx do
    for ending <- [:complete, :discard], _ <- 1..@rounds do
      owner = user!(ctx)
      draft = draft_gym!(owner)

      {:ok, _} =
        set_location(owner, draft.id, %{
          "country_code" => "PL",
          "city" => "Warsaw",
          "address_line" => "ul. Ząbkowska 31"
        })

      ender =
        case ending do
          :complete -> fn -> Gyms.complete_setup(owner, draft.id) end
          :discard -> fn -> Gyms.discard_draft(owner, draft.id) end
        end

      [started, _ended] = concurrently([act(owner, draft.id, :start), ender])

      case {ending, started} do
        {_, {:error, {:conflict, %{setup_status: "draft"}}}} -> assert rows(draft.id) == []
        {:complete, {:ok, %{status: :in_progress}}} -> assert [_] = rows(draft.id)
        {:discard, {:error, :not_found}} -> assert rows(draft.id) == []
      end
    end
  end

  test "one owner on two gyms at once: each gym keeps its own outcome", ctx do
    for _ <- 1..@rounds do
      owner = user!(ctx)
      gym_a = completed_gym!(owner)
      gym_b = completed_gym!(owner, %{"name" => "Second Gym"})

      [{:ok, a}, {:ok, b}] =
        concurrently([act(owner, gym_a.id, :complete), act(owner, gym_b.id, :dismiss)])

      assert {a.gym_id, a.status} == {gym_a.id, :completed}
      assert {b.gym_id, b.status} == {gym_b.id, :dismissed}
      assert events(gym_a.id) == [:first_run_completed]
      assert events(gym_b.id) == [:first_run_dismissed]
    end
  end
end
