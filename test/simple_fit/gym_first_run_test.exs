defmodule SimpleFit.GymFirstRunTest do
  @moduledoc """
  The gym first run and setup checklist (SF-90): lifecycle and terminal
  semantics, the derived checklist, owner-only access and tenant isolation,
  multi-gym and ownership-transfer behaviour, deletion, audit, telemetry,
  database invariants and the unchanged entry resolver. Concurrency is in
  `SimpleFit.GymFirstRunRaceTest`.
  """

  use SimpleFit.DataCase, async: true

  import SimpleFit.CoachingHelpers, only: [complete_coach!: 2]
  import SimpleFit.FighterOnboardingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.Accounts.User
  alias SimpleFit.{Entry, Gyms}
  alias SimpleFit.Gyms.{AuditEvent, Gym, GymFirstRun, StaffMembership}

  @future [:add_class, :invite_members, :first_check_in]

  # A completed gym with no accepted staff invitation (SF-93): inviting staff
  # is available, every other future item is coming later.
  @fresh Map.new([
           {:create_gym, :completed},
           {:invite_staff, :available} | Enum.map(@future, &{&1, :coming_later})
         ])

  defp completed_with_owner do
    owner = registered!("first-run")
    %{owner: owner, gym: completed_gym!(owner)}
  end

  defp rows(gym_id), do: Repo.all(from(r in GymFirstRun, where: r.gym_id == ^gym_id))

  defp events(gym_id, types),
    do: gym_id |> audit_events() |> Enum.filter(&(&1.event_type in types))

  defp first_run_events(gym_id),
    do: events(gym_id, [:first_run_completed, :first_run_dismissed])

  defp statuses(checklist), do: Map.new(checklist, &{&1.key, &1.status})

  defp start(user, gym_id), do: Gyms.first_run_transition(user, gym_id, :start, %{})
  defp complete(user, gym_id), do: Gyms.first_run_transition(user, gym_id, :complete, %{})
  defp dismiss(user, gym_id), do: Gyms.first_run_transition(user, gym_id, :dismiss, %{})

  describe "reading" do
    test "a completed gym the owner has not started: not_started, a truthful checklist, nothing written" do
      %{owner: owner, gym: gym} = completed_with_owner()

      assert {:ok, state} = Gyms.get_first_run(owner, gym.id)
      assert state.gym_id == gym.id
      assert state.status == :not_started
      assert {state.started_at, state.completed_at, state.dismissed_at} == {nil, nil, nil}

      assert Enum.map(state.checklist, & &1.key) ==
               [:create_gym, :add_class, :invite_staff, :invite_members, :first_check_in]

      assert statuses(state.checklist) == @fresh

      assert rows(gym.id) == []
      assert first_run_events(gym.id) == []
    end

    test "a draft is unavailable: creating the gym is still available, nothing else is" do
      owner = registered!("first-run-draft")
      draft = draft_gym!(owner)

      assert {:ok, state} = Gyms.get_first_run(owner, draft.id)
      assert state.status == :unavailable
      assert statuses(state.checklist).create_gym == :available
      assert statuses(state.checklist).invite_staff == :coming_later
      assert Enum.all?(@future, &(statuses(state.checklist)[&1] == :coming_later))
    end

    test "completing the setup through SF-85 is what completes create_gym" do
      owner = registered!("first-run-setup")
      draft = draft_gym!(owner)

      {:ok, _} =
        set_location(owner, draft.id, %{
          "country_code" => "PL",
          "city" => "Warsaw",
          "address_line" => "ul. Ząbkowska 31"
        })

      {:ok, _, :completed} = Gyms.complete_setup(owner, draft.id)

      assert {:ok, %{status: :not_started, checklist: checklist}} =
               Gyms.get_first_run(owner, draft.id)

      assert statuses(checklist).create_gym == :completed
    end
  end

  describe "the lifecycle" do
    test "start, resume and complete: final, idempotent, one audit event, gym unchanged" do
      %{owner: owner, gym: gym} = completed_with_owner()
      before = Repo.get!(Gym, gym.id)

      assert {:ok, %{status: :in_progress, started_at: %DateTime{} = started}} =
               start(owner, gym.id)

      # A second client resumes: the first start is kept.
      assert {:ok, %{status: :in_progress, started_at: ^started}} = start(owner, gym.id)

      assert {:ok, %{status: :in_progress, started_at: ^started}} =
               Gyms.get_first_run(owner, gym.id)

      assert {:ok, %{status: :completed, completed_at: %DateTime{} = done} = state} =
               complete(owner, gym.id)

      assert state.started_at == started
      assert DateTime.compare(done, started) != :lt
      assert state.dismissed_at == nil

      # Repeating returns the same terminal state.
      assert {:ok, ^state} = complete(owner, gym.id)
      assert {:ok, ^state} = Gyms.get_first_run(owner, gym.id)

      # Never reopened, never turned into the other outcome.
      assert start(owner, gym.id) == {:error, {:conflict, %{first_run: "completed"}}}
      assert dismiss(owner, gym.id) == {:error, {:conflict, %{first_run: "completed"}}}

      assert [%AuditEvent{event_type: :first_run_completed} = event] = first_run_events(gym.id)
      assert event.actor_user_id == owner.id

      assert {event.staff_membership_id, event.from_role, event.to_role, event.reason} ==
               {nil, nil, nil, nil}

      # The gym itself (setup, revision) is untouched, and so is the checklist.
      assert Repo.get!(Gym, gym.id) == before
      assert statuses(state.checklist) == @fresh
    end

    test "finishing without a recorded start counts as started at that moment" do
      %{owner: owner, gym: gym} = completed_with_owner()

      assert {:ok, %{status: :completed, started_at: at, completed_at: at}} =
               complete(owner, gym.id)

      assert %DateTime{} = at
    end

    test "skip without starting: dismissed, final, and no checklist item is fabricated" do
      %{owner: owner, gym: gym} = completed_with_owner()

      assert {:ok, %{status: :dismissed, started_at: nil, dismissed_at: %DateTime{}} = state} =
               dismiss(owner, gym.id)

      assert {:ok, ^state} = dismiss(owner, gym.id)
      assert complete(owner, gym.id) == {:error, {:conflict, %{first_run: "dismissed"}}}
      assert start(owner, gym.id) == {:error, {:conflict, %{first_run: "dismissed"}}}

      assert statuses(state.checklist) == @fresh

      assert [%AuditEvent{event_type: :first_run_dismissed}] = first_run_events(gym.id)
    end

    test "ending a started introduction keeps the start" do
      %{owner: owner, gym: gym} = completed_with_owner()
      {:ok, %{started_at: started}} = start(owner, gym.id)

      assert {:ok, %{status: :dismissed, started_at: ^started, dismissed_at: dismissed}} =
               dismiss(owner, gym.id)

      assert DateTime.compare(dismissed, started) != :lt
    end

    test "a draft has no first run: every transition is a conflict and nothing is written" do
      owner = registered!("first-run-draft")
      draft = draft_gym!(owner)

      for action <- [:start, :complete, :dismiss] do
        assert Gyms.first_run_transition(owner, draft.id, action, %{}) ==
                 {:error, {:conflict, %{setup_status: "draft"}}}
      end

      assert rows(draft.id) == []
      assert first_run_events(draft.id) == []
    end

    test "a request body is refused: no forged user, gym or checklist field" do
      %{owner: owner, gym: gym} = completed_with_owner()
      other = registered!("first-run-forged")

      for body <- [
            %{"user_id" => other.id},
            %{"gym_id" => Ecto.UUID.generate()},
            %{"checklist" => %{"invite_staff" => true}},
            %{"status" => "completed"},
            %{"invited_staff" => true}
          ],
          action <- [:start, :complete, :dismiss] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Gyms.first_run_transition(owner, gym.id, action, body)

        [key] = Map.keys(body)
        assert errors_on(changeset)[key] == ["is not accepted"]
      end

      assert rows(gym.id) == []
    end
  end

  describe "who" do
    test "only the owner: other staff are forbidden and change nothing" do
      %{owner: owner, gym: gym} = completed_with_owner()

      for role <- [:manager, :coach, :front_desk] do
        staff = registered!("first-run-#{role}")
        staff!(gym.id, staff, role)

        assert Gyms.get_first_run(staff, gym.id) == {:error, :forbidden}

        for action <- [:start, :complete, :dismiss] do
          assert Gyms.first_run_transition(staff, gym.id, action, %{}) == {:error, :forbidden}
        end
      end

      assert rows(gym.id) == []
      assert {:ok, %{status: :not_started}} = Gyms.get_first_run(owner, gym.id)
    end

    test "outsiders, unknown and malformed ids: not_found, never a hint" do
      %{gym: gym} = completed_with_owner()
      outsider = registered!("first-run-outsider")

      for id <- [gym.id, Ecto.UUID.generate(), "not-a-uuid", nil, 42] do
        assert Gyms.get_first_run(outsider, id) == {:error, :not_found}
        assert Gyms.first_run_transition(outsider, id, :complete, %{}) == {:error, :not_found}
      end

      assert rows(gym.id) == []
    end

    test "a Fighter or Coach profile alone grants nothing at a gym" do
      %{gym: gym} = completed_with_owner()
      fighter = registered!("first-run-fighter")
      complete_fighter_onboarding!(fighter)
      coach = registered!("first-run-coach")
      complete_coach!(coach, "Coach Marek")

      for user <- [fighter, coach] do
        assert Gyms.get_first_run(user, gym.id) == {:error, :not_found}
        assert Gyms.first_run_transition(user, gym.id, :dismiss, %{}) == {:error, :not_found}
      end
    end

    test "a revoked staff member loses access on the next call" do
      %{owner: owner, gym: gym} = completed_with_owner()
      manager = registered!("first-run-revoked")
      membership = staff!(gym.id, manager, :manager)

      assert Gyms.get_first_run(manager, gym.id) == {:error, :forbidden}
      {:ok, _} = Gyms.revoke_staff_membership(owner, gym.id, membership.id)
      assert Gyms.get_first_run(manager, gym.id) == {:error, :not_found}
    end

    test "after an ownership transfer the previous owner keeps nothing and the new owner starts fresh" do
      %{owner: owner, gym: gym} = completed_with_owner()
      manager = registered!("first-run-new-owner")
      target = staff!(gym.id, manager, :manager)
      {:ok, _} = complete(owner, gym.id)

      {:ok, _} = Gyms.transfer_ownership(owner, gym.id, target.id, :stay_as_manager)

      # The previous owner is now a manager: no first-run controls.
      assert Gyms.get_first_run(owner, gym.id) == {:error, :forbidden}
      assert Gyms.first_run_transition(owner, gym.id, :start, %{}) == {:error, :forbidden}

      # The new owner's introduction is their own; the gym's facts are the same.
      assert {:ok, %{status: :not_started, checklist: checklist}} =
               Gyms.get_first_run(manager, gym.id)

      assert statuses(checklist).create_gym == :completed
      assert {:ok, %{status: :dismissed}} = dismiss(manager, gym.id)

      assert rows(gym.id) |> Enum.map(&{&1.user_id, &1.completed_at != nil}) |> Enum.sort() ==
               Enum.sort([{owner.id, true}, {manager.id, false}])
    end
  end

  describe "several gyms" do
    test "one owner, two gyms: independent states, and a new gym resets nothing" do
      owner = registered!("first-run-multi")
      gym_a = completed_gym!(owner)
      {:ok, %{status: :completed} = a_state} = complete(owner, gym_a.id)

      gym_b = completed_gym!(owner, %{"name" => "Second Gym"})
      assert {:ok, %{status: :not_started}} = Gyms.get_first_run(owner, gym_b.id)
      assert {:ok, ^a_state} = Gyms.get_first_run(owner, gym_a.id)

      {:ok, %{status: :dismissed}} = dismiss(owner, gym_b.id)
      assert {:ok, ^a_state} = Gyms.get_first_run(owner, gym_a.id)

      # A third gym, still a draft, changes neither.
      draft = draft_gym!(owner, %{"name" => "Third Gym"})
      assert {:ok, %{status: :unavailable}} = Gyms.get_first_run(owner, draft.id)
      assert {:ok, ^a_state} = Gyms.get_first_run(owner, gym_a.id)
    end

    test "the owner of gym A cannot act on gym B" do
      %{owner: owner_a} = completed_with_owner()
      %{owner: owner_b, gym: gym_b} = completed_with_owner()

      assert Gyms.first_run_transition(owner_a, gym_b.id, :complete, %{}) == {:error, :not_found}
      assert {:ok, %{status: :not_started}} = Gyms.get_first_run(owner_b, gym_b.id)
    end
  end

  describe "deletion" do
    test "rows go with their gym and with their user" do
      %{owner: owner, gym: gym} = completed_with_owner()
      {:ok, _} = start(owner, gym.id)

      # A former staff member's row goes with their account.
      former = registered!("first-run-former")
      membership = staff!(gym.id, former, :manager)

      Repo.insert!(%GymFirstRun{
        gym_id: gym.id,
        user_id: former.id,
        dismissed_at: DateTime.utc_now()
      })

      {:ok, _} = Gyms.revoke_staff_membership(owner, gym.id, membership.id)
      Repo.delete!(Repo.get!(User, former.id))
      assert [%GymFirstRun{user_id: owner_id}] = rows(gym.id)
      assert owner_id == owner.id

      # Deleting the gym (no endpoint does; closure is future) takes the row.
      Repo.delete!(Repo.get!(Gym, gym.id))
      assert rows(gym.id) == []
    end

    test "the database refuses to delete a user who still owns the gym" do
      %{owner: owner, gym: gym} = completed_with_owner()
      {:ok, _} = start(owner, gym.id)

      assert_raise Ecto.ConstraintError, ~r/user_present_while_active/, fn ->
        Repo.delete!(Repo.get!(User, owner.id))
      end
    end
  end

  describe "database invariants" do
    setup do
      %{owner: owner, gym: gym} = completed_with_owner()
      %{owner: owner, gym: gym}
    end

    test "one row per gym and user", %{owner: owner, gym: gym} do
      {:ok, _} = start(owner, gym.id)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%GymFirstRun{
          gym_id: gym.id,
          user_id: owner.id,
          started_at: DateTime.utc_now()
        })
      end
    end

    test "an outcome is final, the start and the keys never move", %{owner: owner, gym: gym} do
      {:ok, _} = start(owner, gym.id)
      [row] = rows(gym.id)

      for change <- [
            [started_at: DateTime.add(row.started_at, 60)],
            [user_id: registered!("first-run-move").id]
          ] do
        assert_raise Ecto.ConstraintError, ~r/gym_first_runs_immutable/, fn ->
          row |> Ecto.Changeset.change(change) |> Repo.update!()
        end
      end

      {:ok, _} = complete(owner, gym.id)
      [row] = rows(gym.id)

      for change <- [[completed_at: nil], [dismissed_at: DateTime.utc_now()]] do
        assert_raise Ecto.ConstraintError, ~r/gym_first_runs_final/, fn ->
          row |> Ecto.Changeset.change(change) |> Repo.update!()
        end
      end
    end

    test "check constraints: one outcome, something happened, completion after a start",
         %{owner: owner, gym: gym} do
      now = DateTime.utc_now()

      for {fields, constraint} <- [
            {[started_at: now, completed_at: now, dismissed_at: now], "one_outcome"},
            {[], "something_happened"},
            {[completed_at: now], "completed_was_started"},
            {[started_at: now, completed_at: DateTime.add(now, -1)], "completed_was_started"},
            {[started_at: now, dismissed_at: DateTime.add(now, -1)], "dismissed_after_start"}
          ] do
        assert_raise Ecto.ConstraintError, ~r/#{constraint}/, fn ->
          Repo.insert!(struct!(GymFirstRun, [gym_id: gym.id, user_id: owner.id] ++ fields))
        end
      end
    end

    test "audit events of the first run are append-only", %{owner: owner, gym: gym} do
      {:ok, _} = complete(owner, gym.id)
      [event] = first_run_events(gym.id)

      assert_raise Ecto.ConstraintError, ~r/gym_audit_events_append_only/, fn ->
        event |> Ecto.Changeset.change(event_type: :first_run_dismissed) |> Repo.update!()
      end
    end
  end

  describe "boundaries" do
    test "the entry resolver answers the same before and after the first run ends" do
      %{owner: owner, gym: gym} = completed_with_owner()
      {:ok, before} = Entry.resolve(owner)

      {:ok, _} = start(owner, gym.id)
      {:ok, started} = Entry.resolve(owner)
      {:ok, _} = complete(owner, gym.id)
      {:ok, completed} = Entry.resolve(owner)

      assert before == started
      assert before == completed
      assert before.destination == :gym_home
    end

    test "telemetry carries the outcome only, never an id" do
      %{owner: owner, gym: gym} = completed_with_owner()
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "gym-first-run-#{inspect(ref)}",
        for(
          action <- [:start, :complete, :dismiss],
          do: [:simple_fit, :gyms, :first_run, action]
        ),
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("gym-first-run-#{inspect(ref)}") end)

      {:ok, _} = start(owner, gym.id)
      {:error, _} = Gyms.first_run_transition(owner, gym.id, :dismiss, %{"user_id" => owner.id})
      {:ok, _} = complete(owner, gym.id)
      {:error, _} = dismiss(owner, gym.id)

      outcomes =
        for _ <- 1..4 do
          assert_receive {^ref, [:simple_fit, :gyms, :first_run, action], %{count: 1}, metadata}
          assert Map.keys(metadata) == [:outcome]
          {action, metadata.outcome}
        end

      assert outcomes == [start: :ok, dismiss: :invalid, complete: :ok, dismiss: :conflict]
    end

    test "staff memberships are never created or changed by the first run" do
      %{owner: owner, gym: gym} = completed_with_owner()
      before = Repo.all(from(m in StaffMembership, where: m.gym_id == ^gym.id))
      {:ok, _} = complete(owner, gym.id)
      assert Repo.all(from(m in StaffMembership, where: m.gym_id == ^gym.id)) == before
    end
  end
end
