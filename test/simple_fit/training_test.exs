defmodule SimpleFit.TrainingTest do
  @moduledoc """
  Training sessions (SF-62; ADR 0023): assignment only under the coach's own
  active, disclosing relationship with sharing ready; idempotent creation;
  strict plan validation with PostgreSQL zone rules (DST gaps and overlaps);
  planned-only changes; terminal states; the relationship end cancelling
  planned future sessions; each side's projection and paging.
  """

  # Not async: the sharing configuration is global.
  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.CoachingHelpers
  import SimpleFit.LegalHelpers
  import SimpleFit.TrainingHelpers

  alias SimpleFit.{Accounts, Coaching, Repo, Training}
  alias SimpleFit.Training.TrainingSession

  setup do
    configure_sharing()
    coach = coach_user!("Coach Marek")
    fighter = fighter_user!()
    relationship = activate!(coach, fighter)
    %{coach: coach, fighter: fighter, rel: relationship.id}
  end

  defp codes({:error, %Ecto.Changeset{} = changeset}),
    do: SimpleFitWeb.ChangesetErrors.details(changeset).field_codes

  defp row(id), do: Repo.get!(TrainingSession, id)

  # Sharing stays ready under a new published version while the version the
  # relationship was accepted under is withdrawn (ADR 0022).
  defp withdraw_accepted_version! do
    build_registry!([
      %{
        document_id: "fighter-coach-disclosure",
        version: version(),
        scope: "basic_profile",
        status: "withdrawn"
      },
      %{
        document_id: "fighter-coach-disclosure",
        version: "fighter-coach-disclosure-test-2",
        scope: "basic_profile"
      },
      %{document_id: "coach-data-rules", version: data_rules_version()}
    ])

    set_sharing(
      disclosures: %{
        version() => :basic_profile,
        "fighter-coach-disclosure-test-2" => :basic_profile
      },
      current: "fighter-coach-disclosure-test-2"
    )

    true = Coaching.sharing_ready?()
  end

  describe "assignment" do
    test "a coach assigns one planned session to the relationship's fighter", ctx do
      {:ok, view, :created} = Training.create_session(ctx.coach, session_attrs(ctx.rel))

      assert view.status == :planned and view.relationship_id == ctx.rel
      assert view.training_type == :technical and view.duration_minutes == 60
      assert view.fighter.display_name
      assert is_nil(view.completed_at) and is_nil(view.cancelled_at)

      session = row(view.id)
      assert session.fighter_profile_id == SimpleFit.Fighters.get_profile(ctx.fighter).id
      assert session.coach_profile_id == SimpleFit.Coaches.get_profile(ctx.coach).id

      assert {:ok, mine} = Training.get_fighter_session(ctx.fighter, view.id)
      assert mine.coach.display_name == "Coach Marek" and mine.title == "Technical boxing"
    end

    test "only the five SF-49 training types exist", ctx do
      for type <- ~w(technical sparring pads strength_conditioning roadwork) do
        assert {:ok, _, :created} =
                 Training.create_session(
                   ctx.coach,
                   session_attrs(ctx.rel, %{"training_type" => type})
                 )
      end

      for type <- ~w(conditioning bag_work pt fitness amateur personal_training) do
        assert %{"training_type" => ["invalid_choice"]} =
                 codes(
                   Training.create_session(
                     ctx.coach,
                     session_attrs(ctx.rel, %{"training_type" => type})
                   )
                 )
      end
    end

    test "a repeated client_request_id returns the same session and creates nothing", ctx do
      attrs = session_attrs(ctx.rel)
      {:ok, first, :created} = Training.create_session(ctx.coach, attrs)
      {:ok, again, :existing} = Training.create_session(ctx.coach, %{attrs | "title" => "Other"})

      assert again.id == first.id and again.title == "Technical boxing"
      assert Repo.aggregate(TrainingSession, :count) == 1
    end

    test "two sessions with identical plans are two sessions", ctx do
      attrs = session_attrs(ctx.rel)
      {:ok, a, :created} = Training.create_session(ctx.coach, attrs)

      {:ok, b, :created} =
        Training.create_session(ctx.coach, %{attrs | "client_request_id" => Ecto.UUID.generate()})

      refute a.id == b.id
    end

    test "a key reused for another relationship is a conflict", ctx do
      other = activate!(ctx.coach, fighter_user!())
      attrs = session_attrs(ctx.rel)
      {:ok, _, :created} = Training.create_session(ctx.coach, attrs)

      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               Training.create_session(ctx.coach, %{attrs | "relationship_id" => other.id})
    end

    test "another coach's key space is separate", ctx do
      attrs = session_attrs(ctx.rel)
      {:ok, _, :created} = Training.create_session(ctx.coach, attrs)
      other_coach = coach_user!("Coach Ola")
      other_rel = activate!(other_coach, ctx.fighter)

      assert {:ok, _, :created} =
               Training.create_session(other_coach, %{attrs | "relationship_id" => other_rel.id})
    end

    test "no relationship, no assignment: foreign, unknown, malformed and ended ids", ctx do
      stranger = coach_user!("Coach Ola")
      assert {:error, :not_found} = Training.create_session(stranger, session_attrs(ctx.rel))

      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :not_found} = Training.create_session(ctx.coach, session_attrs(id))
      end

      :ok = Coaching.end_relationship(ctx.fighter, :fighter, ctx.rel)
      assert {:error, :not_found} = Training.create_session(ctx.coach, session_attrs(ctx.rel))
      assert Repo.aggregate(TrainingSession, :count) == 0
    end

    test "the fighter of the relationship cannot assign, nor a user with no coach profile", ctx do
      assert {:error, :not_found} = Training.create_session(ctx.fighter, session_attrs(ctx.rel))

      assert {:error, :not_found} =
               Training.create_session(registered_user!(), session_attrs(ctx.rel))
    end

    test "nothing is assigned while sharing is off or the accepted disclosure is withdrawn",
         ctx do
      set_sharing(enabled: false)
      assert {:error, :not_found} = Training.create_session(ctx.coach, session_attrs(ctx.rel))

      set_sharing([])
      withdraw_accepted_version!()
      assert {:error, :not_found} = Training.create_session(ctx.coach, session_attrs(ctx.rel))
      assert Repo.aggregate(TrainingSession, :count) == 0
    end

    test "client-chosen owners, status and terminal facts are rejected, never used", ctx do
      forged = %{
        "coach_profile_id" => Ecto.UUID.generate(),
        "fighter_profile_id" => Ecto.UUID.generate(),
        "status" => "completed",
        "completed_at" => in_days(0),
        "cancelled_by" => "system"
      }

      assert %{"coach_profile_id" => ["invalid"], "status" => ["invalid"]} =
               codes(Training.create_session(ctx.coach, session_attrs(ctx.rel, forged)))

      assert Repo.aggregate(TrainingSession, :count) == 0
    end
  end

  describe "plan validation" do
    test "required fields, lengths and ranges are enforced, never truncated", ctx do
      for {field, value, code} <- [
            {"title", "", "required"},
            {"title", "   ", "required"},
            {"title", String.duplicate("a", 81), "too_long"},
            {"duration_minutes", 4, "out_of_range"},
            {"duration_minutes", 601, "out_of_range"},
            {"duration_minutes", "sixty", "invalid_type"},
            {"notes", "", "too_short"},
            {"notes", String.duplicate("n", 2001), "too_long"},
            {"client_request_id", "nope", "invalid_type"},
            {"starts_at", "tomorrow", "invalid_type"}
          ] do
        assert %{^field => [^code]} =
                 codes(
                   Training.create_session(ctx.coach, session_attrs(ctx.rel, %{field => value}))
                 ),
               "#{field}=#{inspect(value)}"
      end

      assert %{"title" => ["required"], "time_zone" => ["required"]} =
               codes(
                 Training.create_session(
                   ctx.coach,
                   Map.drop(session_attrs(ctx.rel), ["title", "time_zone"])
                 )
               )
    end

    test "time zones: IANA ids and UTC only, validated by PostgreSQL", ctx do
      for zone <- ~w(Europe/Warsaw Europe/Kyiv Europe/Kiev America/Argentina/Buenos_Aires UTC) do
        assert {:ok, view, :created} =
                 Training.create_session(
                   ctx.coach,
                   session_attrs(ctx.rel, %{"time_zone" => zone})
                 ),
               zone

        assert view.time_zone == zone
      end

      for zone <- ~w(Mars/Phobos CET EST Etc/GMT+1 posix/Europe/Warsaw europe/warsaw) ++ [""] do
        assert %{"time_zone" => [_]} =
                 codes(
                   Training.create_session(
                     ctx.coach,
                     session_attrs(ctx.rel, %{"time_zone" => zone})
                   )
                 ),
               zone
      end
    end

    test "starts_at needs an explicit offset and lies in the allowed window", ctx do
      assert %{"starts_at" => ["invalid_type"]} =
               codes(
                 Training.create_session(
                   ctx.coach,
                   session_attrs(ctx.rel, %{"starts_at" => "2026-12-01T10:00:00"})
                 )
               )

      for days <- [-2, 366] do
        assert %{"starts_at" => ["out_of_range"]} =
                 codes(
                   Training.create_session(
                     ctx.coach,
                     session_attrs(ctx.rel, %{"starts_at" => in_days(days)})
                   )
                 )
      end

      assert {:ok, _, :created} =
               Training.create_session(
                 ctx.coach,
                 session_attrs(ctx.rel, %{"starts_at" => in_days(0)})
               )
    end

    test "DST: a repeated autumn wall time keeps both instants; a spring gap cannot be sent",
         ctx do
      warsaw = %{"time_zone" => "Europe/Warsaw"}

      # 2026-10-25 02:30 happens twice in Warsaw (CEST +02:00, then CET +01:00).
      {:ok, first, :created} =
        Training.create_session(
          ctx.coach,
          session_attrs(ctx.rel, Map.put(warsaw, "starts_at", "2026-10-25T02:30:00+02:00"))
        )

      {:ok, second, :created} =
        Training.create_session(
          ctx.coach,
          session_attrs(ctx.rel, Map.put(warsaw, "starts_at", "2026-10-25T02:30:00+01:00"))
        )

      assert first.starts_at == ~U[2026-10-25 00:30:00.000000Z]
      assert second.starts_at == ~U[2026-10-25 01:30:00.000000Z]

      # 2027-03-28 02:30 does not exist in Warsaw: neither offset is Warsaw's
      # offset at the instant it would name.
      for offset <- ["+01:00", "+02:00"] do
        assert %{"starts_at" => ["invalid"]} =
                 codes(
                   Training.create_session(
                     ctx.coach,
                     session_attrs(
                       ctx.rel,
                       Map.put(warsaw, "starts_at", "2027-03-28T02:30:00" <> offset)
                     )
                   )
                 )
      end

      # The instants either side of the gap, and UTC instants, are fine.
      for at <- ["2027-03-28T01:59:00+01:00", "2027-03-28T03:00:00+02:00", "2027-03-28T01:30:00Z"] do
        assert {:ok, _, :created} =
                 Training.create_session(
                   ctx.coach,
                   session_attrs(ctx.rel, Map.put(warsaw, "starts_at", at))
                 ),
               at
      end
    end

    test "an offset from another zone is rejected; the same instant in UTC is accepted", ctx do
      attrs = session_attrs(ctx.rel, %{"time_zone" => "Europe/Warsaw"})

      assert %{"starts_at" => ["invalid"]} =
               codes(
                 Training.create_session(ctx.coach, %{
                   attrs
                   | "starts_at" => "2026-12-01T10:00:00-05:00"
                 })
               )

      assert {:ok, view, :created} =
               Training.create_session(ctx.coach, %{attrs | "starts_at" => "2026-12-01T15:00:00Z"})

      assert view.starts_at == ~U[2026-12-01 15:00:00.000000Z]
    end
  end

  describe "update" do
    setup ctx, do: %{session: assign!(ctx.coach, ctx.rel)}

    test "only the fields sent change; notes can be cleared", ctx do
      {:ok, view} =
        Training.update_session(ctx.coach, ctx.session.id, %{
          "title" => "Pads",
          "training_type" => "pads",
          "notes" => nil
        })

      assert view.title == "Pads" and view.training_type == :pads and is_nil(view.notes)
      assert view.duration_minutes == 60 and view.time_zone == "Europe/Warsaw"
      assert {:ok, %{title: "Pads"}} = Training.get_fighter_session(ctx.fighter, ctx.session.id)
      assert Repo.aggregate(TrainingSession, :count) == 1
    end

    test "status, owners and unknown fields cannot be patched", ctx do
      for attrs <- [
            %{"status" => "completed"},
            %{"relationship_id" => Ecto.UUID.generate()},
            %{"fighter_profile_id" => Ecto.UUID.generate()},
            %{"cancelled_at" => in_days(0)}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Training.update_session(ctx.coach, ctx.session.id, attrs)
      end

      assert row(ctx.session.id).status == :planned
    end

    test "required fields cannot be cleared and validation matches create", ctx do
      assert %{"title" => ["required"]} =
               codes(Training.update_session(ctx.coach, ctx.session.id, %{"title" => nil}))

      assert %{"time_zone" => ["invalid"]} =
               codes(
                 Training.update_session(ctx.coach, ctx.session.id, %{
                   "time_zone" => "Mars/Phobos"
                 })
               )

      assert %{"starts_at" => ["out_of_range"]} =
               codes(
                 Training.update_session(ctx.coach, ctx.session.id, %{"starts_at" => in_days(400)})
               )
    end

    test "rescheduling validates the new instant against the session's zone", ctx do
      assert %{"starts_at" => ["invalid"]} =
               codes(
                 Training.update_session(ctx.coach, ctx.session.id, %{
                   "starts_at" => "2027-03-28T02:30:00+01:00"
                 })
               )

      assert {:ok, %{starts_at: ~U[2027-03-28 01:30:00.000000Z]}} =
               Training.update_session(ctx.coach, ctx.session.id, %{
                 "starts_at" => "2027-03-28T03:30:00+02:00"
               })
    end

    test "a cancelled or completed session cannot change", ctx do
      {:ok, _} = Training.cancel_session(ctx.coach, ctx.session.id)

      assert {:error, {:conflict, %{status: "cancelled"}}} =
               Training.update_session(ctx.coach, ctx.session.id, %{"title" => "Later"})

      done = assign!(ctx.coach, ctx.rel)
      complete!(done.id)

      assert {:error, {:conflict, %{status: "completed"}}} =
               Training.update_session(ctx.coach, done.id, %{"title" => "Later"})
    end

    test "foreign coaches, the fighter, ended relationships and the gate answer not_found", ctx do
      stranger = coach_user!("Coach Ola")

      assert {:error, :not_found} =
               Training.update_session(stranger, ctx.session.id, %{"title" => "x"})

      assert {:error, :not_found} =
               Training.update_session(ctx.fighter, ctx.session.id, %{"title" => "x"})

      assert {:error, :not_found} = Training.update_session(ctx.coach, "nope", %{"title" => "x"})

      set_sharing(enabled: false)

      assert {:error, :not_found} =
               Training.update_session(ctx.coach, ctx.session.id, %{"title" => "x"})

      set_sharing([])

      :ok = Coaching.end_relationship(ctx.coach, :coach, ctx.rel)

      assert {:error, :not_found} =
               Training.update_session(ctx.coach, ctx.session.id, %{"title" => "x"})
    end
  end

  describe "cancel" do
    setup ctx, do: %{session: assign!(ctx.coach, ctx.rel)}

    test "cancels once; a repeat returns it unchanged", ctx do
      {:ok, cancelled} = Training.cancel_session(ctx.coach, ctx.session.id)
      assert cancelled.status == :cancelled and cancelled.cancelled_by == :coach
      assert is_nil(cancelled.cancel_reason) and cancelled.cancelled_at

      {:ok, again} = Training.cancel_session(ctx.coach, ctx.session.id)
      assert again.cancelled_at == cancelled.cancelled_at

      assert {:ok, %{status: :cancelled}} =
               Training.get_fighter_session(ctx.fighter, ctx.session.id)
    end

    test "a completed session cannot be cancelled", ctx do
      complete!(ctx.session.id)

      assert {:error, {:conflict, %{status: "completed"}}} =
               Training.cancel_session(ctx.coach, ctx.session.id)

      assert row(ctx.session.id).status == :completed
    end

    test "another coach and the fighter cannot cancel", ctx do
      assert {:error, :not_found} =
               Training.cancel_session(coach_user!("Coach Ola"), ctx.session.id)

      assert {:error, :not_found} = Training.cancel_session(ctx.fighter, ctx.session.id)
      assert row(ctx.session.id).status == :planned
    end

    test "cancelling works under a relationship whose disclosure was withdrawn, not when sharing is off",
         ctx do
      second = assign!(ctx.coach, ctx.rel)

      withdraw_accepted_version!()

      assert {:error, :not_found} =
               Training.update_session(ctx.coach, ctx.session.id, %{"title" => "Later"})

      assert {:ok, %{status: :cancelled}} = Training.cancel_session(ctx.coach, ctx.session.id)

      set_sharing(enabled: false)
      assert {:error, :not_found} = Training.cancel_session(ctx.coach, second.id)
      assert row(second.id).status == :planned
    end
  end

  describe "relationship end" do
    test "cancels planned future sessions only, in the end itself", ctx do
      future = assign!(ctx.coach, ctx.rel, %{"starts_at" => in_days(3)})
      later = assign!(ctx.coach, ctx.rel, %{"starts_at" => in_days(30)})
      started = assign!(ctx.coach, ctx.rel, %{"starts_at" => in_days(0)})
      past_due(started.id)
      done = assign!(ctx.coach, ctx.rel)
      complete!(done.id)
      dropped = assign!(ctx.coach, ctx.rel)
      {:ok, _} = Training.cancel_session(ctx.coach, dropped.id)

      :ok = Coaching.end_relationship(ctx.fighter, :fighter, ctx.rel)

      for id <- [future.id, later.id] do
        assert %{status: :cancelled, cancelled_by: :system, cancel_reason: :relationship_ended} =
                 row(id)
      end

      assert row(started.id).status == :planned
      assert row(done.id).status == :completed
      assert %{status: :cancelled, cancelled_by: :coach} = row(dropped.id)

      # Ending again changes nothing.
      :ok = Coaching.end_relationship(ctx.coach, :coach, ctx.rel)
      assert row(future.id).cancelled_by == :system
    end

    test "the fighter keeps the history; the former coach sees nothing", ctx do
      session = assign!(ctx.coach, ctx.rel)
      :ok = Coaching.end_relationship(ctx.coach, :coach, ctx.rel)

      {:ok, mine} = Training.get_fighter_session(ctx.fighter, session.id)
      assert mine.status == :cancelled and is_nil(mine.coach)
      assert mine.coach_display_name_at_end == "Coach Marek"

      assert {:error, :not_found} = Training.get_coach_session(ctx.coach, session.id)
      assert {:ok, %{entries: []}} = Training.list_coach_sessions(ctx.coach, %{})
      assert {:error, :not_found} = Training.cancel_session(ctx.coach, session.id)
    end
  end

  describe "reads" do
    test "a fighter reads only their own sessions, from every coach, whatever the gate", ctx do
      own = assign!(ctx.coach, ctx.rel)
      second_coach = coach_user!("Coach Ola")
      second_rel = activate!(second_coach, ctx.fighter)
      other = assign!(second_coach, second_rel.id)
      someone_else = fighter_user!()
      foreign_rel = activate!(ctx.coach, someone_else)
      foreign = assign!(ctx.coach, foreign_rel.id)

      set_sharing(enabled: false)
      {:ok, %{entries: entries}} = Training.list_fighter_sessions(ctx.fighter, %{})
      assert Enum.map(entries, & &1.id) |> Enum.sort() == Enum.sort([own.id, other.id])
      assert {:error, :not_found} = Training.get_fighter_session(ctx.fighter, foreign.id)
      assert {:error, :not_found} = Training.get_fighter_session(someone_else, own.id)
      assert {:error, :not_found} = Training.list_coach_sessions(ctx.coach, %{})
    end

    test "a user holding both profiles reads each side separately", ctx do
      dual = coach_user!("Coach Dual")
      SimpleFit.FighterOnboardingHelpers.complete_fighter_onboarding!(dual)
      dual_rel = activate!(ctx.coach, dual)
      assigned_to_dual = assign!(ctx.coach, dual_rel.id)
      dual_coaching_rel = activate!(dual, ctx.fighter)
      by_dual = assign!(dual, dual_coaching_rel.id)

      assert {:ok, %{entries: [%{id: fighter_side}]}} = Training.list_fighter_sessions(dual, %{})
      assert fighter_side == assigned_to_dual.id
      assert {:ok, %{entries: [%{id: coach_side}]}} = Training.list_coach_sessions(dual, %{})
      assert coach_side == by_dual.id
      assert {:error, :not_found} = Training.get_coach_session(dual, assigned_to_dual.id)
      assert {:error, :not_found} = Training.get_fighter_session(dual, by_dual.id)
    end

    test "keyset pages by start then id, with filters and opaque cursors", ctx do
      same = in_days(5)
      ids = for _ <- 1..3, do: assign!(ctx.coach, ctx.rel, %{"starts_at" => same}).id
      early = assign!(ctx.coach, ctx.rel, %{"starts_at" => in_days(1)})
      late = assign!(ctx.coach, ctx.rel, %{"starts_at" => in_days(9)})
      {:ok, _} = Training.cancel_session(ctx.coach, late.id)

      expected = [early.id | Enum.sort(ids)] ++ [late.id]

      walk = fn walk, params, acc ->
        {:ok, %{entries: entries, next_cursor: cursor}} =
          Training.list_coach_sessions(ctx.coach, Map.put(params, "limit", 2))

        acc = acc ++ Enum.map(entries, & &1.id)
        if cursor, do: walk.(walk, Map.put(params, "cursor", cursor), acc), else: acc
      end

      assert walk.(walk, %{}, []) == expected

      assert {:ok, %{entries: [%{id: id}]}} =
               Training.list_coach_sessions(ctx.coach, %{"status" => "cancelled"})

      assert id == late.id

      {:ok, %{entries: window}} =
        Training.list_coach_sessions(ctx.coach, %{"from" => in_days(2), "to" => in_days(8)})

      assert Enum.map(window, & &1.id) |> Enum.sort() == Enum.sort(ids)

      {:ok, %{entries: by_rel}} =
        Training.list_coach_sessions(ctx.coach, %{"relationship_id" => ctx.rel})

      assert length(by_rel) == 5

      for bad <- [
            %{"cursor" => "nope"},
            %{"limit" => 0},
            %{"status" => "done"},
            %{"from" => in_days(5), "to" => in_days(1)}
          ] do
        assert {:error, %Ecto.Changeset{}} = Training.list_coach_sessions(ctx.coach, bad),
               inspect(bad)
      end
    end

    test "the coach sees only the disclosed fighter identity", ctx do
      session = assign!(ctx.coach, ctx.rel)
      {:ok, view} = Training.get_coach_session(ctx.coach, session.id)
      assert Map.keys(view.fighter) |> Enum.sort() == [:display_name, :username]
      refute Map.has_key?(view, :fighter_profile_id)
    end
  end

  describe "database guards" do
    test "a session must belong to its relationship's coach and fighter", ctx do
      session = row(assign!(ctx.coach, ctx.rel).id)
      other_fighter = SimpleFit.Fighters.get_profile(fighter_user!()).id

      assert_raise Ecto.ConstraintError, ~r/training_sessions_relationship_parties_fkey/, fn ->
        Repo.insert!(
          %{
            session
            | id: nil,
              client_request_id: Ecto.UUID.generate(),
              fighter_profile_id: other_fighter
          },
          log: false
        )
      end
    end

    test "rows start planned, under an active relationship, and terminal rows are immutable",
         ctx do
      session = row(assign!(ctx.coach, ctx.rel).id)
      fresh = %{session | id: nil, client_request_id: Ecto.UUID.generate()}

      assert_raise Ecto.ConstraintError, ~r/created_planned/, fn ->
        Repo.insert!(%{fresh | status: :completed, completed_at: DateTime.utc_now()})
      end

      assert_raise Ecto.ConstraintError, ~r/time_zone_valid/, fn ->
        Repo.insert!(%{fresh | time_zone: "Mars/Phobos"})
      end

      complete!(session.id)

      assert_raise Postgrex.Error, ~r/terminal_immutable/, fn ->
        Repo.update_all(from(s in TrainingSession, where: s.id == ^session.id),
          set: [status: :planned, completed_at: nil]
        )
      end

      :ok = Coaching.end_relationship(ctx.coach, :coach, ctx.rel)

      assert_raise Ecto.ConstraintError, ~r/active_relationship/, fn -> Repo.insert!(fresh) end
    end

    test "deleting either user removes their sessions (cascade)", ctx do
      session = assign!(ctx.coach, ctx.rel)
      {:ok, _} = Accounts.User |> Repo.get!(ctx.coach.id) |> Repo.delete()
      refute Repo.get(TrainingSession, session.id)
    end
  end

  # SF-63 owns completion: tests reach the completed state directly, the way
  # the backend's own transition will (planned -> completed).
  defp complete!(id) do
    {1, _} =
      Repo.update_all(from(s in TrainingSession, where: s.id == ^id),
        set: [status: :completed, completed_at: DateTime.utc_now()]
      )
  end

  # A planned session whose start has already passed (the window forbids
  # assigning it; time moves on).
  defp past_due(id) do
    {1, _} =
      Repo.update_all(from(s in TrainingSession, where: s.id == ^id),
        set: [starts_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )
  end
end
