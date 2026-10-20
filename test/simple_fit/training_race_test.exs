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
end
