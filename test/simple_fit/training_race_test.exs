defmodule SimpleFit.TrainingRaceTest do
  @moduledoc """
  Training sessions under true concurrency, on separate database connections
  (outside the SQL sandbox), so unique indexes, triggers and row locks are
  exercised for real (ADR 0023). Rows are committed, so every test removes
  the users it created (profiles, relationships and sessions cascade).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.CoachingHelpers
  import SimpleFit.TrainingHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaching, Repo, Training}
  alias SimpleFit.Training.TrainingSession

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

    coach = coach_user!() |> track(users)
    fighter = fighter_user!() |> track(users)
    %{users: users, coach: coach, fighter: fighter, rel: activate!(coach, fighter).id}
  end

  defp track(user, users) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(20_000)

  defp sessions_of(rel),
    do: Repo.all(from(s in TrainingSession, where: s.coach_fighter_relationship_id == ^rel))

  test "simultaneous creates with one client_request_id insert exactly one session", ctx do
    attrs = session_attrs(ctx.rel)

    results =
      concurrently(for _ <- 1..10, do: fn -> Training.create_session(ctx.coach, attrs) end)

    assert Enum.all?(results, &match?({:ok, _, _}, &1))
    assert results |> Enum.map(fn {:ok, v, _} -> v.id end) |> Enum.uniq() |> length() == 1
    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert length(sessions_of(ctx.rel)) == 1
  end

  test "simultaneous creates with distinct keys create distinct sessions", ctx do
    results =
      concurrently(
        for _ <- 1..10, do: fn -> Training.create_session(ctx.coach, session_attrs(ctx.rel)) end
      )

    assert Enum.all?(results, &match?({:ok, _, :created}, &1))
    assert length(sessions_of(ctx.rel)) == 10
  end

  test "create versus end: never a planned future session under an ended relationship", ctx do
    for _ <- 1..5 do
      coach = coach_user!() |> track(ctx.users)
      rel = activate!(coach, ctx.fighter).id

      results =
        concurrently(
          [fn -> Coaching.end_relationship(ctx.fighter, :fighter, rel) end] ++
            for(_ <- 1..6, do: fn -> Training.create_session(coach, session_attrs(rel)) end)
        )

      assert hd(results) == :ok

      assert Enum.all?(
               tl(results),
               &(match?({:ok, _, :created}, &1) or &1 == {:error, :not_found})
             )

      # Whatever won, every session that exists was cancelled by the end.
      for s <- sessions_of(rel) do
        assert s.status == :cancelled and s.cancelled_by == :system
      end
    end
  end

  test "update versus cancel: one wins; a change never lands on a cancelled session", ctx do
    for _ <- 1..5 do
      session = assign!(ctx.coach, ctx.rel)

      [update, cancel] =
        concurrently([
          fn -> Training.update_session(ctx.coach, session.id, %{"title" => "Changed"}) end,
          fn -> Training.cancel_session(ctx.coach, session.id) end
        ])

      assert {:ok, %{status: :cancelled}} = cancel
      stored = Repo.get!(TrainingSession, session.id)

      case update do
        {:ok, _} -> assert stored.title == "Changed"
        {:error, {:conflict, %{status: "cancelled"}}} -> assert stored.title == "Technical boxing"
      end
    end
  end

  test "concurrent cancels record one cancellation", ctx do
    session = assign!(ctx.coach, ctx.rel)

    results =
      concurrently(for _ <- 1..8, do: fn -> Training.cancel_session(ctx.coach, session.id) end)

    times = results |> Enum.map(fn {:ok, v} -> v.cancelled_at end) |> Enum.uniq()
    assert length(times) == 1
  end

  test "cancel versus end: the session ends cancelled once, by whichever came first", ctx do
    sessions = for _ <- 1..4, do: assign!(ctx.coach, ctx.rel)

    concurrently(
      [fn -> Coaching.end_relationship(ctx.coach, :coach, ctx.rel) end] ++
        Enum.map(sessions, fn s -> fn -> Training.cancel_session(ctx.coach, s.id) end end)
    )

    for s <- sessions_of(ctx.rel) do
      assert s.status == :cancelled
      assert {s.cancelled_by, s.cancel_reason} in [{:coach, nil}, {:system, :relationship_ended}]
    end
  end

  test "create versus deleting the coach's account leaves nothing behind", ctx do
    coach = coach_user!()
    rel = activate!(coach, ctx.fighter).id

    concurrently(
      [fn -> Repo.delete(Repo.get!(User, coach.id)) end] ++
        for(_ <- 1..5, do: fn -> Training.create_session(coach, session_attrs(rel)) end)
    )

    assert sessions_of(rel) == []
  end

  test "multiple coaches assign to one fighter in parallel", ctx do
    coaches = for _ <- 1..4, do: coach_user!() |> track(ctx.users)
    rels = Enum.map(coaches, &activate!(&1, ctx.fighter).id)

    results =
      concurrently(
        Enum.zip(coaches, rels)
        |> Enum.map(fn {c, r} -> fn -> Training.create_session(c, session_attrs(r)) end end)
      )

    assert Enum.all?(results, &match?({:ok, _, :created}, &1))
    assert {:ok, %{entries: entries}} = Training.list_fighter_sessions(ctx.fighter, %{})
    assert length(entries) == 4
  end

  # The future SF-63 completion locks the session row only (ADR 0023). An
  # update holding the relationship and session locks and a session-only
  # transition serialize on the session row without deadlocking.
  test "update versus a session-only transition (future completion) does not deadlock", ctx do
    for _ <- 1..5 do
      session = assign!(ctx.coach, ctx.rel)

      [update, complete] =
        concurrently([
          fn -> Training.update_session(ctx.coach, session.id, %{"duration_minutes" => 90}) end,
          fn ->
            Repo.transaction(fn ->
              locked =
                Repo.one!(
                  from(s in TrainingSession, where: s.id == ^session.id, lock: "FOR UPDATE")
                )

              if locked.status == :planned do
                Repo.update_all(from(s in TrainingSession, where: s.id == ^session.id),
                  set: [status: :completed, completed_at: DateTime.utc_now()]
                )
              end
            end)
          end
        ])

      assert {:ok, _} = complete
      assert match?({:ok, _}, update) or update == {:error, {:conflict, %{status: "completed"}}}
      assert Repo.get!(TrainingSession, session.id).status == :completed
    end
  end

  ## SF-63 completion

  # A session that has already started (completable): assigned, then moved a
  # few minutes into the past.
  defp started!(coach, rel) do
    session = assign!(coach, rel)

    {1, _} =
      Repo.update_all(from(s in TrainingSession, where: s.id == ^session.id),
        set: [starts_at: DateTime.add(DateTime.utc_now(), -300, :second)]
      )

    session
  end

  defp consistent!(id) do
    s = Repo.get!(TrainingSession, id)

    case s.status do
      :completed -> assert s.completed_at && is_nil(s.cancelled_at) && is_nil(s.cancelled_by)
      :cancelled -> assert s.cancelled_at && is_nil(s.completed_at)
      :planned -> assert is_nil(s.completed_at) && is_nil(s.cancelled_at)
    end

    s
  end

  test "ten simultaneous completions record one completion time", ctx do
    session = started!(ctx.coach, ctx.rel)

    results =
      concurrently(
        for _ <- 1..10, do: fn -> Training.complete_session(ctx.fighter, session.id) end
      )

    times = results |> Enum.map(fn {:ok, v} -> v.completed_at end) |> Enum.uniq()
    assert length(times) == 1
    assert consistent!(session.id).completed_at == hd(times)
  end

  test "completion versus the coach's cancellation: exactly one terminal state wins", ctx do
    for _ <- 1..8 do
      session = started!(ctx.coach, ctx.rel)

      [complete, cancel] =
        concurrently([
          fn -> Training.complete_session(ctx.fighter, session.id) end,
          fn -> Training.cancel_session(ctx.coach, session.id) end
        ])

      stored = consistent!(session.id)

      case stored.status do
        :completed ->
          assert {:ok, _} = complete
          assert cancel == {:error, {:conflict, %{status: "completed"}}}

        :cancelled ->
          assert {:ok, _} = cancel
          assert complete == {:error, {:conflict, %{status: "cancelled"}}}
      end
    end
  end

  test "completion versus the relationship end: disjoint sets, every row consistent", ctx do
    coach = coach_user!() |> track(ctx.users)
    rel = activate!(coach, ctx.fighter).id
    started = for _ <- 1..4, do: started!(coach, rel)
    future = for _ <- 1..4, do: assign!(coach, rel, %{"starts_at" => in_days(2)})

    results =
      concurrently(
        [fn -> Coaching.end_relationship(ctx.fighter, :fighter, rel) end] ++
          Enum.map(started ++ future, fn s ->
            fn -> Training.complete_session(ctx.fighter, s.id) end
          end)
      )

    assert hd(results) == :ok
    for s <- started, do: assert(consistent!(s.id).status == :completed)

    for s <- future do
      stored = consistent!(s.id)
      assert stored.status == :cancelled and stored.cancelled_by == :system
    end
  end

  test "completion versus a coach update serializes on the session row", ctx do
    for _ <- 1..5 do
      session = started!(ctx.coach, ctx.rel)

      [update, complete] =
        concurrently([
          fn -> Training.update_session(ctx.coach, session.id, %{"title" => "Changed"}) end,
          fn -> Training.complete_session(ctx.fighter, session.id) end
        ])

      assert {:ok, %{status: :completed}} = complete
      assert match?({:ok, _}, update) or update == {:error, {:conflict, %{status: "completed"}}}
      assert consistent!(session.id).status == :completed
    end
  end

  test "completion versus deleting the fighter's account leaves nothing half done", ctx do
    fighter = fighter_user!()
    rel = activate!(ctx.coach, fighter).id
    session = started!(ctx.coach, rel)

    [deleted, complete] =
      concurrently([
        fn -> Repo.delete(Repo.get!(User, fighter.id)) end,
        fn -> Training.complete_session(fighter, session.id) end
      ])

    assert {:ok, _} = deleted
    assert match?({:ok, _}, complete) or complete == {:error, :not_found}
    refute Repo.get(TrainingSession, session.id)
  end

  test "reads during completion see planned or completed, never a half state", ctx do
    session = started!(ctx.coach, ctx.rel)

    results =
      concurrently(
        [fn -> Training.complete_session(ctx.fighter, session.id) end] ++
          for(_ <- 1..8, do: fn -> Training.get_fighter_session(ctx.fighter, session.id) end) ++
          for(
            _ <- 1..8,
            do: fn -> Training.list_coach_sessions(ctx.coach, %{"view" => "history"}) end
          )
      )

    for {:ok, view} <- results, Map.has_key?(view, :status) do
      assert (view.status == :planned and is_nil(view.completed_at)) or
               (view.status == :completed and view.completed_at)
    end
  end
end
