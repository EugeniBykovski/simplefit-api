defmodule SimpleFit.GymTimetableRaceTest do
  @moduledoc """
  The gym timetable under true concurrency and real commits (SF-97), on
  separate connections outside the SQL sandbox: the gym row lock, the
  unique series dates, the idempotency indexes and the venue and
  instructor exclusion constraints (across gyms) are exercised for real.
  Every test checks the final database state; rounds repeat to surface
  intermittent deadlocks. Committed rows are removed afterwards (through
  the purge switch).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers
  import SimpleFit.TimetableHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Clock, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, ClassOccurrence, ClassSeries, Gym, StaffMembership, Venue}

  @now ~U[2026-01-05 12:00:00Z]

  setup do
    Sandbox.mode(Repo, :auto)
    Clock.freeze(@now)
    reset_limits()
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

      purge_gyms!(gym_ids)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      reset_limits()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    owner = track(users, registered_as!(registered!("ttrace-owner"), "Yauheni Bykovski"))
    gym = completed_gym!(owner)
    venue = venue!(owner, gym.id, %{"capacity" => 30})
    template = template!(owner, gym.id, %{"default_venue_id" => venue.venue_id})
    %{users: users, owner: owner, gym: gym, venue: venue, template: template}
  end

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp reset_limits do
    Repo.delete_all("auth_rate_limits")
    Repo.delete_all("rate_limit_events")
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(60_000)

  defp occurrences(gym_id),
    do: Repo.all(from(o in ClassOccurrence, where: o.gym_id == ^gym_id, order_by: o.starts_at))

  defp events(gym_id, type),
    do:
      Repo.aggregate(
        from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type),
        :count
      )

  defp class_attrs(ctx, raw, extra \\ %{}),
    do: Map.merge(%{"template_id" => ctx.template.template_id, "starts_at" => raw}, extra)

  test "12 parallel creations with one key create one class and one event", ctx do
    attrs =
      class_attrs(ctx, "2026-01-10T10:00:00+01:00", %{"client_request_id" => Ecto.UUID.generate()})

    results = concurrently(for _ <- 1..12, do: fn -> one_time(ctx.owner, ctx.gym.id, attrs) end)

    assert Enum.count(results, &match?({:ok, {_, :created}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {_, :existing}}, &1)) == 11
    assert [_] = occurrences(ctx.gym.id)
    assert events(ctx.gym.id, :class_occurrence_created) == 1
  end

  test "parallel series creations with one key and parallel regenerations never duplicate a date",
       ctx do
    attrs = %{
      "client_request_id" => Ecto.UUID.generate(),
      "template_id" => ctx.template.template_id,
      "weekdays" => [1, 3, 5],
      "local_start_time" => "18:00",
      "starts_on" => "2026-01-05",
      "ends_on" => "2026-04-30"
    }

    results = concurrently(for _ <- 1..8, do: fn -> series(ctx.owner, ctx.gym.id, attrs) end)
    assert Enum.count(results, &match?({:ok, {_, :created}}, &1)) == 1
    [{:ok, {view, _}} | _] = results
    count = length(series_rows(view.series_id))

    regenerations =
      concurrently(
        for _ <- 1..8,
            do: fn ->
              Gyms.generate_class_series(
                ctx.owner,
                session(ctx.owner),
                ctx.gym.id,
                view.series_id
              )
            end
      )

    assert Enum.all?(regenerations, &match?({:ok, {_, 0}}, &1))
    rows = series_rows(view.series_id)
    assert length(rows) == count
    assert length(Enum.uniq_by(rows, & &1.series_local_date)) == count
    assert Repo.aggregate(from(s in ClassSeries, where: s.gym_id == ^ctx.gym.id), :count) == 1
  end

  test "two classes racing for one venue slot: exactly one; adjacent ones both", ctx do
    for round <- 1..5 do
      day = 9 + round
      raw = "2026-01-#{day}T18:00:00+01:00"

      results =
        concurrently(
          for minutes <- [0, 15, 30, 45],
              do: fn ->
                one_time(
                  ctx.owner,
                  ctx.gym.id,
                  class_attrs(
                    ctx,
                    String.replace(raw, "18:00", "18:#{String.pad_leading("#{minutes}", 2, "0")}")
                  )
                )
              end
        )

      assert Enum.count(results, &match?({:ok, {_, :created}}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, {:conflict, %{schedule: "venue_unavailable"}}}, &1)
             ) == 3

      adjacent =
        concurrently([
          fn ->
            one_time(ctx.owner, ctx.gym.id, class_attrs(ctx, "2026-01-#{day}T20:00:00+01:00"))
          end,
          fn ->
            one_time(ctx.owner, ctx.gym.id, class_attrs(ctx, "2026-01-#{day}T21:00:00+01:00"))
          end
        ])

      assert Enum.all?(adjacent, &match?({:ok, {_, :created}}, &1))
    end

    # No two scheduled classes overlap in the venue.
    rows = Enum.filter(occurrences(ctx.gym.id), &(&1.status == :scheduled))

    for [a, b] <- Enum.chunk_every(rows, 2, 1, :discard) do
      assert DateTime.compare(a.ends_at, b.starts_at) != :gt
    end
  end

  test "one instructor racing for overlapping classes at two gyms: exactly one, a generic conflict for the other",
       ctx do
    coach = track(ctx.users, email_user!(address("ttrace-coach"), "Tomasz Zieliński"))
    owner_b = track(ctx.users, registered_as!(registered!("ttrace-owner-b"), "Ola Nowak"))
    gym_b = completed_gym!(owner_b)
    venue_b = venue!(owner_b, gym_b.id)
    template_b = template!(owner_b, gym_b.id, %{"default_venue_id" => venue_b.venue_id})

    row_a = staff!(ctx.gym.id, coach, :coach)
    row_b = staff!(gym_b.id, coach, :coach)

    for round <- 1..5 do
      raw = "2026-02-0#{round}T10:00:00+01:00"

      results =
        concurrently([
          fn ->
            one_time(
              ctx.owner,
              ctx.gym.id,
              class_attrs(ctx, raw, %{"instructor_staff_membership_id" => row_a.id})
            )
          end,
          fn ->
            one_time(owner_b, gym_b.id, %{
              "template_id" => template_b.template_id,
              "starts_at" => String.replace(raw, "10:00", "10:30"),
              "instructor_staff_membership_id" => row_b.id
            })
          end
        ])

      assert Enum.count(results, &match?({:ok, {_, :created}}, &1)) == 1
      assert [{:error, {:conflict, details}}] = Enum.filter(results, &match?({:error, _}, &1))
      assert details == %{schedule: "instructor_unavailable"}
    end

    assert Repo.aggregate(
             from(o in ClassOccurrence,
               where: o.instructor_user_id == ^coach.id and o.status == :scheduled
             ),
             :count
           ) == 5
  end

  test "reschedule racing cancel, and two reschedules racing: one applies, the others are stale",
       ctx do
    for round <- 1..5 do
      class =
        one_time!(ctx.owner, ctx.gym.id, class_attrs(ctx, "2026-03-0#{round}T10:00:00+01:00"))

      id = class.occurrence_id

      results =
        concurrently([
          fn ->
            Gyms.update_class_occurrence(ctx.owner, session(ctx.owner), ctx.gym.id, id, %{
              "expected_revision" => 1,
              "starts_at" => "2026-03-0#{round}T12:00:00+01:00"
            })
          end,
          fn ->
            Gyms.update_class_occurrence(ctx.owner, session(ctx.owner), ctx.gym.id, id, %{
              "expected_revision" => 1,
              "capacity" => 10
            })
          end,
          fn ->
            Gyms.cancel_class_occurrence(ctx.owner, session(ctx.owner), ctx.gym.id, id, %{
              "expected_revision" => 1
            })
          end
        ])

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:conflict, _}}, &1)) == 2
      stored = stored_occurrence(id)
      assert stored.revision == 2
    end
  end

  test "cancel racing regeneration: a cancelled class never comes back", ctx do
    view =
      series!(ctx.owner, ctx.gym.id, %{
        "template_id" => ctx.template.template_id,
        "weekdays" => [2],
        "local_start_time" => "19:00",
        "starts_on" => "2026-01-06",
        "ends_on" => "2026-03-31"
      })

    for row <- Enum.take(series_rows(view.series_id), 5) do
      concurrently([
        fn ->
          Gyms.cancel_class_occurrence(ctx.owner, session(ctx.owner), ctx.gym.id, row.id, %{
            "expected_revision" => 1
          })
        end,
        fn ->
          Gyms.generate_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, view.series_id)
        end,
        fn ->
          Gyms.generate_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, view.series_id)
        end
      ])

      assert stored_occurrence(row.id).status == :cancelled
    end

    rows = series_rows(view.series_id)
    assert length(rows) == length(Enum.uniq_by(rows, & &1.series_local_date))
    assert Enum.count(rows, &(&1.status == :cancelled)) == 5
  end

  test "a series change racing a one-class exception: both serialize, the exception survives",
       ctx do
    view =
      series!(ctx.owner, ctx.gym.id, %{
        "template_id" => ctx.template.template_id,
        "weekdays" => [4],
        "local_start_time" => "18:00",
        "starts_on" => "2026-01-08",
        "ends_on" => "2026-02-26"
      })

    [first | _] = series_rows(view.series_id)

    results =
      concurrently([
        fn ->
          Gyms.update_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, view.series_id, %{
            "expected_revision" => 1,
            "local_start_time" => "17:00"
          })
        end,
        fn ->
          Gyms.update_class_occurrence(ctx.owner, session(ctx.owner), ctx.gym.id, first.id, %{
            "expected_revision" => 1,
            "capacity" => 12
          })
        end
      ])

    stored = stored_occurrence(first.id)

    case results do
      [{:ok, _}, {:ok, _}] ->
        # The exception came second: it kept the series' new time and its own capacity.
        assert stored.capacity == 12 and stored.rescheduled_at

      [{:ok, _}, {:error, {:conflict, %{revision: "stale"}}}] ->
        # The series came first and bumped the class's revision.
        assert stored.capacity == 30 or stored.capacity == 16
    end

    rows = series_rows(view.series_id)
    assert length(rows) == length(Enum.uniq_by(rows, & &1.series_local_date))
  end

  test "venue deactivation racing a class creation: never a scheduled class in an inactive venue",
       ctx do
    for round <- 1..5 do
      venue = venue!(ctx.owner, ctx.gym.id)

      concurrently([
        fn ->
          Gyms.deactivate_venue(ctx.owner, session(ctx.owner), ctx.gym.id, venue.venue_id, %{
            "expected_revision" => 1
          })
        end,
        fn ->
          one_time(
            ctx.owner,
            ctx.gym.id,
            class_attrs(ctx, "2026-04-0#{round}T10:00:00+02:00", %{"venue_id" => venue.venue_id})
          )
        end
      ])

      stored = Repo.get!(Venue, venue.venue_id)

      classes =
        Repo.all(
          from(o in ClassOccurrence,
            where: o.venue_id == ^venue.venue_id and o.status == :scheduled
          )
        )

      assert (stored.status == :inactive and classes == []) or
               (stored.status == :active and length(classes) == 1)
    end
  end

  test "staff revocation racing an instructor assignment: never a class still to come with an ended instructor",
       ctx do
    for round <- 1..5 do
      coach = track(ctx.users, email_user!(address("ttrace-rev"), "Ewa Malec"))
      row = staff!(ctx.gym.id, coach, :coach)

      concurrently([
        fn -> Gyms.end_staff_membership(ctx.owner, ctx.gym.id, row.id) end,
        fn ->
          one_time(
            ctx.owner,
            ctx.gym.id,
            class_attrs(ctx, "2026-05-0#{round}T10:00:00+02:00", %{
              "instructor_staff_membership_id" => row.id
            })
          )
        end
      ])

      assert Repo.get!(StaffMembership, row.id).status == :ended

      assert Repo.all(
               from(o in ClassOccurrence,
                 where:
                   o.instructor_staff_membership_id == ^row.id and o.status == :scheduled and
                     o.starts_at > ^@now
               )
             ) == []
    end
  end

  test "several gyms schedule the same slot independently", ctx do
    gyms =
      for n <- 1..4 do
        owner = track(ctx.users, registered_as!(registered!("ttrace-multi-#{n}"), "Owner #{n}"))
        gym = completed_gym!(owner)
        venue = venue!(owner, gym.id)
        template = template!(owner, gym.id, %{"default_venue_id" => venue.venue_id})
        {owner, gym, template}
      end

    results =
      concurrently(
        for {owner, gym, template} <- gyms,
            do: fn ->
              one_time(owner, gym.id, %{
                "template_id" => template.template_id,
                "starts_at" => "2026-01-10T18:00:00+01:00"
              })
            end
      )

    assert Enum.all?(results, &match?({:ok, {_, :created}}, &1))

    for {owner, gym, _} <- gyms do
      assert {:ok, %{entries: [entry]}} =
               Gyms.list_class_occurrences(owner, gym.id, %{
                 "from" => "2026-01-10T00:00:00Z",
                 "to" => "2026-01-11T00:00:00Z"
               })

      assert entry.gym_id == gym.id
    end
  end

  test "capacity revisions racing on one venue: exactly one applies", ctx do
    for round <- 1..5 do
      venue = venue!(ctx.owner, ctx.gym.id, %{"capacity" => 20})

      results =
        concurrently(
          for capacity <- [10, 12, 14, 16],
              do: fn ->
                Gyms.update_venue(ctx.owner, session(ctx.owner), ctx.gym.id, venue.venue_id, %{
                  "expected_revision" => 1,
                  "capacity" => capacity + round
                })
              end
        )

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:conflict, %{revision: "stale"}}}, &1)) == 3
      assert Repo.get!(Venue, venue.venue_id).revision == 2
    end
  end

  test "a session revoked during writes: no write commits after it", ctx do
    session = session(ctx.owner)

    results =
      concurrently(
        [
          fn ->
            Repo.update_all(from(s in SimpleFit.Accounts.Session, where: s.id == ^session.id),
              set: [revoked_at: DateTime.utc_now(:second), revoked_reason: :logout]
            )
          end
        ] ++
          for(
            minute <- 0..5,
            do: fn ->
              Gyms.create_class_occurrence(
                ctx.owner,
                session,
                ctx.gym.id,
                class_attrs(ctx, "2026-06-01T1#{minute}:00:00+02:00", %{
                  "client_request_id" => Ecto.UUID.generate()
                })
              )
            end
          )
      )

    created = Enum.count(results, &match?({:ok, {_, :created}}, &1))
    revoked = Enum.count(results, &match?({:error, :session_revoked}, &1))
    assert created + revoked == 6
    assert length(occurrences(ctx.gym.id)) == created
    # Audit events exist exactly for committed classes.
    assert events(ctx.gym.id, :class_occurrence_created) == created
  end
end
