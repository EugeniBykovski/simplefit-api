defmodule SimpleFit.TrainingCompletionTest do
  @moduledoc """
  Training completion and read projections (SF-63; ADR 0023): only the
  assigned fighter completes, from the session's start, with a server time;
  repeats are no-ops; cancelled and not-started sessions conflict; preserved
  sessions stay completable after a relationship ends without telling the
  former coach; `view=upcoming|history` with server time, ordering and
  view-bound cursors; the authorization matrix per role.
  """

  # Not async: the sharing configuration is global.
  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.CoachingHelpers
  import SimpleFit.TrainingHelpers

  alias SimpleFit.{Coaching, Repo, Training}
  alias SimpleFit.Training.TrainingSession

  setup do
    configure_sharing()
    coach = coach_user!("Coach Marek")
    fighter = fighter_user!()
    %{coach: coach, fighter: fighter, rel: activate!(coach, fighter).id}
  end

  defp row(id), do: Repo.get!(TrainingSession, id)

  # A session whose start is `minutes` ago (assignment needs a start no more
  # than a day ago; time then moves on).
  defp started!(coach, rel, minutes, overrides \\ %{}) do
    session = assign!(coach, rel, overrides)

    {1, _} =
      Repo.update_all(from(s in TrainingSession, where: s.id == ^session.id),
        set: [starts_at: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)]
      )

    session
  end

  describe "completion" do
    test "the assigned fighter completes a started session; the server sets completed_at", ctx do
      session = started!(ctx.coach, ctx.rel, 10)
      before = DateTime.utc_now()

      {:ok, view} = Training.complete_session(ctx.fighter, session.id)

      assert view.status == :completed
      assert DateTime.compare(view.completed_at, before) != :lt
      assert DateTime.compare(view.completed_at, DateTime.utc_now()) != :gt
      assert %{status: :completed, cancelled_at: nil, cancelled_by: nil} = row(session.id)

      assert {:ok, %{status: :completed, completed_at: at}} =
               Training.get_coach_session(ctx.coach, session.id)

      assert at == view.completed_at
    end

    test "a repeat returns it unchanged, keeping the first completion time", ctx do
      session = started!(ctx.coach, ctx.rel, 10)
      {:ok, first} = Training.complete_session(ctx.fighter, session.id)
      {:ok, again} = Training.complete_session(ctx.fighter, session.id)

      assert again.completed_at == first.completed_at
      assert row(session.id).completed_at == first.completed_at
    end

    test "completion is allowed from the start, never before it", ctx do
      session = assign!(ctx.coach, ctx.rel, %{"starts_at" => in_days(1)})

      assert {:error, {:conflict, %{starts_at: "not_started"}}} =
               Training.complete_session(ctx.fighter, session.id)

      assert row(session.id).status == :planned
    end

    test "there is no deadline: a long past-due session can still be completed", ctx do
      session = started!(ctx.coach, ctx.rel, 60 * 24 * 90)
      assert {:ok, %{status: :completed}} = Training.complete_session(ctx.fighter, session.id)
    end

    test "a cancelled session cannot be completed, and a completed one cannot be cancelled",
         ctx do
      cancelled = started!(ctx.coach, ctx.rel, 10)
      {:ok, _} = Training.cancel_session(ctx.coach, cancelled.id)

      assert {:error, {:conflict, %{status: "cancelled"}}} =
               Training.complete_session(ctx.fighter, cancelled.id)

      done = started!(ctx.coach, ctx.rel, 10)
      {:ok, _} = Training.complete_session(ctx.fighter, done.id)

      assert {:error, {:conflict, %{status: "completed"}}} =
               Training.cancel_session(ctx.coach, done.id)

      assert {:error, {:conflict, %{status: "completed"}}} =
               Training.update_session(ctx.coach, done.id, %{"title" => "x"})
    end

    test "nobody else completes: the coach, another fighter, other users; ids never authorize",
         ctx do
      session = started!(ctx.coach, ctx.rel, 10)

      for user <- [ctx.coach, fighter_user!(), coach_user!("Coach Ola"), registered_user!()] do
        assert {:error, :not_found} = Training.complete_session(user, session.id)
      end

      for id <- ["nope", Ecto.UUID.generate(), nil] do
        assert {:error, :not_found} = Training.complete_session(ctx.fighter, id)
      end

      assert row(session.id).status == :planned
    end

    test "a user holding both profiles completes only sessions assigned to them as fighter",
         ctx do
      dual = coach_user!("Coach Dual")
      SimpleFit.FighterOnboardingHelpers.complete_fighter_onboarding!(dual)
      assigned = started!(ctx.coach, activate!(ctx.coach, dual).id, 10)
      authored = started!(dual, activate!(dual, ctx.fighter).id, 10)

      assert {:error, :not_found} = Training.complete_session(dual, authored.id)
      assert {:ok, %{status: :completed}} = Training.complete_session(dual, assigned.id)
    end

    test "the request carries nothing: any field is rejected", ctx do
      session = started!(ctx.coach, ctx.rel, 10)

      for attrs <- [
            %{"completed_at" => "2020-01-01T00:00:00Z"},
            %{"status" => "completed"},
            %{"rpe" => 7}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Training.complete_session(ctx.fighter, session.id, attrs)

        assert SimpleFitWeb.ChangesetErrors.details(changeset).field_codes |> Map.values() == [
                 ["invalid"]
               ]
      end

      assert row(session.id).status == :planned
    end

    test "completion works while sharing is off and never needs the relationship", ctx do
      session = started!(ctx.coach, ctx.rel, 10)
      set_sharing(enabled: false)
      assert {:ok, %{status: :completed}} = Training.complete_session(ctx.fighter, session.id)
    end
  end

  describe "after a relationship ends" do
    test "a preserved started session is completable; the former coach learns nothing", ctx do
      started = started!(ctx.coach, ctx.rel, 30)
      future = assign!(ctx.coach, ctx.rel, %{"starts_at" => in_days(3)})

      :ok = Coaching.end_relationship(ctx.coach, :coach, ctx.rel)

      assert {:error, {:conflict, %{status: "cancelled"}}} =
               Training.complete_session(ctx.fighter, future.id)

      {:ok, done} = Training.complete_session(ctx.fighter, started.id)
      assert done.status == :completed and is_nil(done.coach)
      assert done.coach_display_name_at_end == "Coach Marek"

      # No reactivation, no new assignment, no coach-side read of the result.
      assert {:ok, %{status: :ended}} = Coaching.get_fighter_relationship(ctx.fighter, ctx.rel)
      assert {:error, :not_found} = Training.get_coach_session(ctx.coach, started.id)

      assert {:ok, %{entries: []}} =
               Training.list_coach_sessions(ctx.coach, %{"view" => "history"})

      assert {:error, :not_found} = Training.create_session(ctx.coach, session_attrs(ctx.rel))
    end
  end

  describe "projections" do
    setup ctx do
      now = DateTime.utc_now()
      at = fn minutes -> DateTime.add(now, minutes * 60, :second) end

      make = fn minutes, duration ->
        s = assign!(ctx.coach, ctx.rel, %{"duration_minutes" => duration})

        {1, _} =
          Repo.update_all(from(x in TrainingSession, where: x.id == ^s.id),
            set: [starts_at: at.(minutes)]
          )

        s.id
      end

      sessions = %{
        later: make.(60 * 24, 60),
        soon: make.(30, 60),
        in_progress: make.(-20, 60),
        past_due: make.(-180, 60),
        done: make.(-120, 60),
        dropped: make.(60 * 48, 60)
      }

      {:ok, _} = Training.complete_session(ctx.fighter, sessions.done)
      {:ok, _} = Training.cancel_session(ctx.coach, sessions.dropped)
      %{s: sessions}
    end

    defp ids({:ok, %{entries: entries}}), do: Enum.map(entries, & &1.id)

    test "upcoming: planned and not yet over, earliest first", ctx do
      expected = [ctx.s.in_progress, ctx.s.soon, ctx.s.later]
      assert ids(Training.list_fighter_sessions(ctx.fighter, %{"view" => "upcoming"})) == expected
      assert ids(Training.list_coach_sessions(ctx.coach, %{"view" => "upcoming"})) == expected
    end

    test "history: completed, cancelled and past-due planned, newest first", ctx do
      expected = [ctx.s.dropped, ctx.s.done, ctx.s.past_due]
      assert ids(Training.list_fighter_sessions(ctx.fighter, %{"view" => "history"})) == expected
      assert ids(Training.list_coach_sessions(ctx.coach, %{"view" => "history"})) == expected

      # A past-due session is never shown as completed.
      assert row(ctx.s.past_due).status == :planned
    end

    test "completed is status=completed; views combine with filters", ctx do
      assert ids(Training.list_fighter_sessions(ctx.fighter, %{"status" => "completed"})) == [
               ctx.s.done
             ]

      assert ids(
               Training.list_fighter_sessions(ctx.fighter, %{
                 "view" => "history",
                 "status" => "planned"
               })
             ) ==
               [ctx.s.past_due]
    end

    test "every session is in exactly one of upcoming and history", ctx do
      upcoming = ids(Training.list_fighter_sessions(ctx.fighter, %{"view" => "upcoming"}))
      history = ids(Training.list_fighter_sessions(ctx.fighter, %{"view" => "history"}))
      all = ids(Training.list_fighter_sessions(ctx.fighter, %{}))

      assert Enum.sort(upcoming ++ history) == Enum.sort(all)
      assert MapSet.disjoint?(MapSet.new(upcoming), MapSet.new(history))
    end

    test "cursors page each view in its own order and are only valid for that view", ctx do
      walk = fn walk, params, acc ->
        {:ok, %{entries: e, next_cursor: c}} =
          Training.list_fighter_sessions(ctx.fighter, Map.put(params, "limit", 1))

        acc = acc ++ Enum.map(e, & &1.id)
        if c, do: walk.(walk, Map.put(params, "cursor", c), acc), else: acc
      end

      assert walk.(walk, %{"view" => "history"}, []) == [
               ctx.s.dropped,
               ctx.s.done,
               ctx.s.past_due
             ]

      assert walk.(walk, %{"view" => "upcoming"}, []) == [
               ctx.s.in_progress,
               ctx.s.soon,
               ctx.s.later
             ]

      {:ok, %{next_cursor: cursor}} =
        Training.list_fighter_sessions(ctx.fighter, %{"view" => "history", "limit" => 1})

      for params <- [%{"view" => "upcoming"}, %{}] do
        assert {:error, %Ecto.Changeset{}} =
                 Training.list_fighter_sessions(ctx.fighter, Map.put(params, "cursor", cursor))
      end

      assert {:error, %Ecto.Changeset{}} =
               Training.list_fighter_sessions(ctx.fighter, %{"view" => "soon"})
    end

    test "projections are per account: another coach's sessions never appear", ctx do
      other = coach_user!("Coach Ola")
      other_session = assign!(other, activate!(other, ctx.fighter).id)

      assert other_session.id in ids(
               Training.list_fighter_sessions(ctx.fighter, %{"view" => "upcoming"})
             )

      refute other_session.id in ids(
               Training.list_coach_sessions(ctx.coach, %{"view" => "upcoming"})
             )

      assert ids(Training.list_coach_sessions(other, %{"view" => "upcoming"})) == [
               other_session.id
             ]
    end
  end
end
