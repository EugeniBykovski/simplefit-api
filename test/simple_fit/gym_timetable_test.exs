defmodule SimpleFit.GymTimetableTest do
  @moduledoc """
  The gym timetable (SF-97) through `SimpleFit.Gyms`: venues, templates,
  one-time and weekly classes, Warsaw daylight-saving rules, conflicts,
  rescheduling, cancellation, the series change policy, permissions,
  instructor release, the `add_class` milestone and independence from the
  coaching and membership domains. The clock is frozen (SF-62), so no test
  depends on today's date.
  """

  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers
  import SimpleFit.TimetableHelpers

  alias SimpleFit.{Clock, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, ClassOccurrence, ClassSeries, FirstRun}

  # Monday 5 January 2026, winter time in Warsaw (UTC+1).
  @now ~U[2026-01-05 12:00:00Z]

  setup do
    Clock.freeze(@now)
    Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)

    owner = registered_as!(registered!("tt-owner"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    venue = venue!(owner, gym.id, %{"name" => "Main Hall", "capacity" => 20})
    template = template!(owner, gym.id, %{"default_venue_id" => venue.venue_id})
    %{owner: owner, gym: gym, venue: venue, template: template}
  end

  defp at(gym, user, raw, extra, ctx) do
    one_time(
      user,
      gym.id,
      Map.merge(%{"template_id" => ctx.template.template_id, "starts_at" => raw}, extra)
    )
  end

  defp codes(%Ecto.Changeset{} = changeset),
    do: SimpleFitWeb.ChangesetErrors.details(changeset).field_codes

  describe "venues" do
    test "belong to the gym's own location, carry a valid zone and are idempotent", ctx do
      attrs = %{
        "client_request_id" => Ecto.UUID.generate(),
        "gym_location_id" => location_id(ctx.gym.id),
        "name" => "Ring 1",
        "time_zone" => "Europe/Warsaw"
      }

      {:ok, {created, :created}} =
        Gyms.create_venue(ctx.owner, session(ctx.owner), ctx.gym.id, attrs)

      assert {:ok, {^created, :existing}} =
               Gyms.create_venue(ctx.owner, session(ctx.owner), ctx.gym.id, attrs)

      for {field, value} <- [
            {"time_zone", "+01:00"},
            {"time_zone", "CET"},
            {"time_zone", "Etc/GMT-1"},
            {"gym_location_id", Ecto.UUID.generate()},
            {"name", "  "},
            {"capacity", 0},
            {"gym_id", ctx.gym.id}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Gyms.create_venue(
                   ctx.owner,
                   session(ctx.owner),
                   ctx.gym.id,
                   Map.merge(attrs, %{"client_request_id" => Ecto.UUID.generate(), field => value})
                 )
      end

      # Another gym's location cannot be used.
      other_owner = registered!("tt-other")
      other = completed_gym!(other_owner)

      assert {:error, changeset} =
               Gyms.create_venue(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 Map.merge(attrs, %{
                   "client_request_id" => Ecto.UUID.generate(),
                   "name" => "Foreign",
                   "gym_location_id" => location_id(other.id)
                 })
               )

      assert codes(changeset) == %{"gym_location_id" => ["invalid_choice"]}

      # A second active venue with the same name (any case) is refused.
      assert {:error, %Ecto.Changeset{}} =
               Gyms.create_venue(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 Map.merge(attrs, %{
                   "client_request_id" => Ecto.UUID.generate(),
                   "name" => "ring 1"
                 })
               )
    end

    test "capacity caps classes; deactivation waits until no class is still to come", ctx do
      class =
        one_time!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "starts_at" => "2026-01-10T10:00:00+01:00"
        })

      assert {:error, {:conflict, %{venue: "capacity_below_upcoming_class"}}} =
               Gyms.update_venue(ctx.owner, session(ctx.owner), ctx.gym.id, ctx.venue.venue_id, %{
                 "expected_revision" => 1,
                 "capacity" => 10
               })

      assert {:error, {:conflict, %{venue: "has_upcoming_classes", upcoming_classes: 1}}} =
               Gyms.deactivate_venue(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 ctx.venue.venue_id,
                 %{
                   "expected_revision" => 1
                 }
               )

      {:ok, _} =
        Gyms.cancel_class_occurrence(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          class.occurrence_id,
          %{
            "expected_revision" => 1
          }
        )

      {:ok, inactive} =
        Gyms.deactivate_venue(ctx.owner, session(ctx.owner), ctx.gym.id, ctx.venue.venue_id, %{
          "expected_revision" => 1
        })

      assert inactive.status == :inactive

      assert {:error, changeset} =
               at(ctx.gym, ctx.owner, "2026-01-11T10:00:00+01:00", %{}, ctx)

      assert codes(changeset) == %{"venue_id" => ["invalid_choice"]}
    end
  end

  describe "templates" do
    test "validate defaults, keep scheduled classes unchanged when edited, archive finally",
         ctx do
      class =
        one_time!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "starts_at" => "2026-01-10T10:00:00+01:00"
        })

      {:ok, updated} =
        Gyms.update_class_template(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          ctx.template.template_id,
          %{
            "expected_revision" => 1,
            "title" => "Advanced Technical Boxing",
            "default_capacity" => 12
          }
        )

      assert updated.title == "Advanced Technical Boxing"
      assert stored_occurrence(class.occurrence_id).title == "Boxing Fundamentals"
      assert stored_occurrence(class.occurrence_id).capacity == 16

      assert {:error, {:conflict, %{revision: "stale", current_revision: 2}}} =
               Gyms.update_class_template(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 ctx.template.template_id,
                 %{
                   "expected_revision" => 1,
                   "title" => "X"
                 }
               )

      assert {:error, changeset} =
               Gyms.update_class_template(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 ctx.template.template_id,
                 %{
                   "title" => "X"
                 }
               )

      assert codes(changeset) == %{"expected_revision" => ["required"]}

      # The default capacity must fit the default venue.
      assert {:error, changeset} =
               Gyms.update_class_template(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 ctx.template.template_id,
                 %{
                   "expected_revision" => 2,
                   "default_capacity" => 30
                 }
               )

      assert codes(changeset) == %{"default_capacity" => ["out_of_range"]}

      {:ok, archived} =
        Gyms.archive_class_template(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          ctx.template.template_id,
          %{
            "expected_revision" => 2
          }
        )

      assert archived.status == :archived
      assert {:error, changeset} = at(ctx.gym, ctx.owner, "2026-01-12T10:00:00+01:00", %{}, ctx)
      assert codes(changeset) == %{"template_id" => ["invalid_choice"]}
      assert stored_occurrence(class.occurrence_id).status == :scheduled
    end
  end

  describe "one-time classes and time zones" do
    test "an explicit offset must be the zone's: winter, summer, spring gap, both autumn instants",
         ctx do
      {:ok, {winter, :created}} = at(ctx.gym, ctx.owner, "2026-01-12T18:00:00+01:00", %{}, ctx)
      assert winter.starts_at == ~U[2026-01-12 17:00:00.000000Z]
      assert winter.local_starts_at == ~N[2026-01-12 18:00:00]
      assert winter.utc_offset_minutes == 60
      assert winter.ends_at == ~U[2026-01-12 18:00:00.000000Z]

      {:ok, {summer, :created}} = at(ctx.gym, ctx.owner, "2026-07-13T18:00:00+02:00", %{}, ctx)
      assert summer.starts_at == ~U[2026-07-13 16:00:00.000000Z]
      assert summer.utc_offset_minutes == 120

      # 02:30 on 29 March 2026 does not exist in Warsaw: neither offset matches.
      for raw <- ["2026-03-29T02:30:00+01:00", "2026-03-29T02:30:00+02:00"] do
        assert {:error, changeset} = at(ctx.gym, ctx.owner, raw, %{}, ctx)
        assert codes(changeset) == %{"starts_at" => ["invalid_format"]}
      end

      # Without an offset the local time is ambiguous: refused.
      assert {:error, changeset} = at(ctx.gym, ctx.owner, "2026-02-01T18:00:00", %{}, ctx)
      assert codes(changeset) == %{"starts_at" => ["invalid_type"]}

      # 02:30 on 25 October 2026 happens twice; the offset tells them apart.
      {:ok, {first, :created}} =
        at(ctx.gym, ctx.owner, "2026-10-25T02:30:00+02:00", %{"duration_minutes" => 30}, ctx)

      other_venue = venue!(ctx.owner, ctx.gym.id, %{"name" => "Ring 2"})

      {:ok, {second, :created}} =
        at(
          ctx.gym,
          ctx.owner,
          "2026-10-25T02:30:00+01:00",
          %{"duration_minutes" => 30, "venue_id" => other_venue.venue_id},
          ctx
        )

      assert first.starts_at == ~U[2026-10-25 00:30:00.000000Z]
      assert second.starts_at == ~U[2026-10-25 01:30:00.000000Z]

      assert {first.local_starts_at, second.local_starts_at} ==
               {~N[2026-10-25 02:30:00], ~N[2026-10-25 02:30:00]}

      assert {first.utc_offset_minutes, second.utc_offset_minutes} == {120, 60}

      # The same venue holds both repeated-hour classes: they do not overlap in elapsed time.
      {:ok, {_again, :created}} =
        at(ctx.gym, ctx.owner, "2026-10-25T02:30:00+01:00", %{"duration_minutes" => 30}, ctx)

      # But a second class in the first repeated 02:30 conflicts with the first.
      assert {:error, {:conflict, %{schedule: "venue_unavailable"}}} =
               at(
                 ctx.gym,
                 ctx.owner,
                 "2026-10-25T02:45:00+02:00",
                 %{"duration_minutes" => 15},
                 ctx
               )

      # Past and beyond a year are refused.
      assert {:error, _} = at(ctx.gym, ctx.owner, "2026-01-05T12:00:00Z", %{}, ctx)
      assert {:error, _} = at(ctx.gym, ctx.owner, "2027-01-07T12:00:00Z", %{}, ctx)
    end

    test "a lost answer retried with its key creates no second class", ctx do
      key = Ecto.UUID.generate()

      attrs = %{
        "client_request_id" => key,
        "template_id" => ctx.template.template_id,
        "starts_at" => "2026-01-10T10:00:00+01:00"
      }

      {:ok, {created, :created}} = one_time(ctx.owner, ctx.gym.id, attrs)
      {:ok, {again, :existing}} = one_time(ctx.owner, ctx.gym.id, attrs)
      assert again.occurrence_id == created.occurrence_id

      assert Repo.aggregate(from(o in ClassOccurrence, where: o.gym_id == ^ctx.gym.id), :count) ==
               1
    end

    test "touching classes share a venue; overlapping ones do not", ctx do
      one_time!(ctx.owner, ctx.gym.id, %{
        "template_id" => ctx.template.template_id,
        "starts_at" => "2026-01-10T18:00:00+01:00"
      })

      {:ok, {_next, :created}} = at(ctx.gym, ctx.owner, "2026-01-10T19:00:00+01:00", %{}, ctx)
      {:ok, {_before, :created}} = at(ctx.gym, ctx.owner, "2026-01-10T17:00:00+01:00", %{}, ctx)

      assert {:error, {:conflict, %{schedule: "venue_unavailable"}}} =
               at(ctx.gym, ctx.owner, "2026-01-10T18:30:00+01:00", %{}, ctx)
    end
  end

  describe "weekly series" do
    test "Mon/Wed/Fri 18:00 Warsaw keeps its wall clock across both DST changes", ctx do
      view =
        series!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "weekdays" => [5, 1, 3, 3],
          "local_start_time" => "18:00",
          "starts_on" => "2026-03-23",
          "ends_on" => "2026-11-06"
        })

      assert view.weekdays == [1, 3, 5]
      assert view.local_start_time == "18:00"
      assert view.skipped_dates == []
      rows = series_rows(view.series_id)
      assert length(rows) == view.scheduled_count

      by_date = Map.new(rows, &{&1.series_local_date, &1.starts_at})
      # Winter (UTC+1) before 29 March, summer (UTC+2) until 25 October, winter again.
      assert by_date[~D[2026-03-27]] == ~U[2026-03-27 17:00:00.000000Z]
      assert by_date[~D[2026-03-30]] == ~U[2026-03-30 16:00:00.000000Z]
      assert by_date[~D[2026-10-23]] == ~U[2026-10-23 16:00:00.000000Z]
      assert by_date[~D[2026-10-26]] == ~U[2026-10-26 17:00:00.000000Z]
      assert Enum.all?(rows, &(Date.day_of_week(&1.series_local_date) in [1, 3, 5]))
    end

    test "a Sunday 02:30 class skips the spring gap and the autumn repeated hour, and reports them",
         ctx do
      view =
        series!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "weekdays" => [7],
          "local_start_time" => "02:30",
          "duration_minutes" => 30,
          "starts_on" => "2026-03-22",
          "ends_on" => "2026-11-01"
        })

      assert view.skipped_dates == [
               %{local_date: ~D[2026-03-29], reason: :nonexistent_local_time},
               %{local_date: ~D[2026-10-25], reason: :ambiguous_local_time}
             ]

      dates = Enum.map(series_rows(view.series_id), & &1.series_local_date)
      refute ~D[2026-03-29] in dates
      refute ~D[2026-10-25] in dates
      assert ~D[2026-03-22] in dates and ~D[2026-04-05] in dates and ~D[2026-11-01] in dates
    end

    test "creation is idempotent; regenerating never duplicates nor revives a cancelled class",
         ctx do
      attrs = %{
        "client_request_id" => Ecto.UUID.generate(),
        "template_id" => ctx.template.template_id,
        "weekdays" => [2],
        "local_start_time" => "19:00",
        "starts_on" => "2026-01-06",
        "ends_on" => "2026-02-24"
      }

      {:ok, {view, :created}} = series(ctx.owner, ctx.gym.id, attrs)
      {:ok, {again, :existing}} = series(ctx.owner, ctx.gym.id, attrs)
      assert again.series_id == view.series_id
      assert length(series_rows(view.series_id)) == 8

      [first | _] = series_rows(view.series_id)

      {:ok, _} =
        Gyms.cancel_class_occurrence(ctx.owner, session(ctx.owner), ctx.gym.id, first.id, %{
          "expected_revision" => 1
        })

      for _ <- 1..3 do
        assert {:ok, {_view, 0}} =
                 Gyms.generate_class_series(
                   ctx.owner,
                   session(ctx.owner),
                   ctx.gym.id,
                   view.series_id
                 )
      end

      rows = series_rows(view.series_id)
      assert length(rows) == 8
      assert hd(rows).status == :cancelled
    end

    test "a conflicting series is refused entirely, naming this gym's dates", ctx do
      one_time!(ctx.owner, ctx.gym.id, %{
        "template_id" => ctx.template.template_id,
        "starts_at" => "2026-01-13T19:30:00+01:00"
      })

      assert {:error, {:conflict, %{schedule: "venue_unavailable", local_dates: ["2026-01-13"]}}} =
               series(ctx.owner, ctx.gym.id, %{
                 "template_id" => ctx.template.template_id,
                 "weekdays" => [2],
                 "local_start_time" => "19:00",
                 "starts_on" => "2026-01-06",
                 "ends_on" => "2026-02-24"
               })

      assert Repo.aggregate(from(s in ClassSeries, where: s.gym_id == ^ctx.gym.id), :count) == 0
    end

    test "rescheduling one class makes it an exception the series leaves alone", ctx do
      view =
        series!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "weekdays" => [2, 4],
          "local_start_time" => "18:00",
          "starts_on" => "2026-01-06",
          "ends_on" => "2026-01-31"
        })

      [first, second | rest] = series_rows(view.series_id)

      {:ok, moved} =
        Gyms.update_class_occurrence(ctx.owner, session(ctx.owner), ctx.gym.id, second.id, %{
          "expected_revision" => 1,
          "starts_at" => "2026-01-08T20:00:00+01:00"
        })

      assert moved.rescheduled
      assert moved.series_local_date == ~D[2026-01-08]
      untouched = for row <- [first | rest], do: {row.id, stored_occurrence(row.id).starts_at}
      assert untouched == for(row <- [first | rest], do: {row.id, row.starts_at})

      # Now the whole series moves to 17:30: every class but the exception follows.
      {:ok, _} =
        Gyms.update_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, view.series_id, %{
          "expected_revision" => 1,
          "local_start_time" => "17:30"
        })

      assert stored_occurrence(second.id).starts_at == ~U[2026-01-08 19:00:00.000000Z]

      for row <- [first | rest] do
        {_date, time} = {row.series_local_date, stored_occurrence(row.id).starts_at}
        assert time.hour == 16 and time.minute == 30
      end
    end

    test "dropping a weekday cancels its classes still to come; adding it back restores them; staff cancellations stay",
         ctx do
      view =
        series!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "weekdays" => [1, 3],
          "local_start_time" => "18:00",
          "starts_on" => "2026-01-05",
          "ends_on" => "2026-01-31"
        })

      wednesdays =
        Enum.filter(series_rows(view.series_id), &(Date.day_of_week(&1.series_local_date) == 3))

      [first_wed | _] = wednesdays

      {:ok, _} =
        Gyms.cancel_class_occurrence(ctx.owner, session(ctx.owner), ctx.gym.id, first_wed.id, %{
          "expected_revision" => 1
        })

      {:ok, _} =
        Gyms.update_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, view.series_id, %{
          "expected_revision" => 1,
          "weekdays" => [1]
        })

      for row <- wednesdays do
        stored = stored_occurrence(row.id)
        assert stored.status == :cancelled

        assert stored.cancel_reason ==
                 if(row.id == first_wed.id, do: :cancelled, else: :series_changed)
      end

      {:ok, back} =
        Gyms.update_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, view.series_id, %{
          "expected_revision" => 2,
          "weekdays" => [1, 3]
        })

      for row <- wednesdays do
        stored = stored_occurrence(row.id)
        assert stored.status == if(row.id == first_wed.id, do: :cancelled, else: :scheduled)
      end

      # One row per date, always.
      assert length(series_rows(view.series_id)) == back.scheduled_count + back.cancelled_count
      dates = Enum.map(series_rows(view.series_id), & &1.series_local_date)
      assert dates == Enum.uniq(dates)
    end

    test "cancelling a series cancels only classes still to come", ctx do
      view =
        series!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "weekdays" => [2],
          "local_start_time" => "18:00",
          "starts_on" => "2026-01-06",
          "ends_on" => "2026-02-24"
        })

      # Two weeks later: the first two Tuesdays have taken place.
      Clock.freeze(~U[2026-01-18 12:00:00Z])

      {:ok, cancelled} =
        Gyms.cancel_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, view.series_id, %{
          "expected_revision" => 1
        })

      assert cancelled.status == :cancelled
      [past1, past2 | future] = series_rows(view.series_id)
      assert past1.status == :scheduled and past2.status == :scheduled

      assert Enum.all?(
               future,
               &(&1.status == :cancelled and &1.cancel_reason == :series_cancelled)
             )

      assert {:error, {:conflict, %{class_series: "cancelled"}}} =
               Gyms.generate_class_series(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 view.series_id
               )

      # A started class cannot be cancelled or moved.
      assert {:error, {:conflict, %{class_occurrence: "started"}}} =
               Gyms.cancel_class_occurrence(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 past2.id,
                 %{
                   "expected_revision" => 1
                 }
               )
    end
  end

  describe "instructors" do
    test "only active owners, managers and coaches of this gym instruct; one class at a time across gyms",
         ctx do
      {coach, coach_row} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Tomasz Zieliński")
      {_desk, desk_row} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk, "Michał Sowa")

      {:ok, {class, :created}} =
        at(
          ctx.gym,
          ctx.owner,
          "2026-01-10T10:00:00+01:00",
          %{"instructor_staff_membership_id" => coach_row.staff_membership_id},
          ctx
        )

      assert class.instructor == %{
               staff_membership_id: coach_row.staff_membership_id,
               name: "Tomasz Z."
             }

      assert {:error, changeset} =
               at(
                 ctx.gym,
                 ctx.owner,
                 "2026-01-11T10:00:00+01:00",
                 %{"instructor_staff_membership_id" => desk_row.staff_membership_id},
                 ctx
               )

      assert codes(changeset) == %{"instructor_staff_membership_id" => ["invalid_choice"]}

      # The same coach also coaches at gym B (an independent membership).
      owner_b = registered_as!(registered!("tt-owner-b"), "Ola Nowak")
      gym_b = completed_gym!(owner_b)
      email_b = address("coach-b")
      link_email!(coach, email_b)
      invitation = invite!(owner_b, gym_b.id, email_b, :coach)
      coach_row_b = accept!(coach, invitation.invitation_id)
      venue_b = venue!(owner_b, gym_b.id)
      template_b = template!(owner_b, gym_b.id, %{"default_venue_id" => venue_b.venue_id})

      # Gym A's membership id means nothing at gym B.
      assert {:error, %Ecto.Changeset{}} =
               one_time(owner_b, gym_b.id, %{
                 "template_id" => template_b.template_id,
                 "starts_at" => "2026-01-12T10:00:00+01:00",
                 "instructor_staff_membership_id" => coach_row.staff_membership_id
               })

      # An overlapping class at gym B with the same person: a generic conflict.
      assert {:error, {:conflict, %{schedule: "instructor_unavailable"} = details}} =
               one_time(owner_b, gym_b.id, %{
                 "template_id" => template_b.template_id,
                 "starts_at" => "2026-01-10T10:30:00+01:00",
                 "instructor_staff_membership_id" => coach_row_b.staff_membership_id
               })

      assert map_size(details) == 1

      {:ok, {_later, :created}} =
        one_time(owner_b, gym_b.id, %{
          "template_id" => template_b.template_id,
          "starts_at" => "2026-01-10T11:00:00+01:00",
          "instructor_staff_membership_id" => coach_row_b.staff_membership_id
        })
    end

    test "an instructor who leaves or becomes front desk is taken off classes still to come",
         ctx do
      {_coach, coach_row} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Tomasz Zieliński")
      {_coach2, coach2_row} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Ewa Malec")

      view =
        series!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "weekdays" => [2],
          "local_start_time" => "18:00",
          "starts_on" => "2026-01-06",
          "ends_on" => "2026-01-27",
          "instructor_staff_membership_id" => coach_row.staff_membership_id
        })

      solo =
        one_time!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "starts_at" => "2026-01-17T10:00:00+01:00",
          "instructor_staff_membership_id" => coach2_row.staff_membership_id
        })

      # One Tuesday has taken place when the coach is removed.
      Clock.freeze(~U[2026-01-08 12:00:00Z])
      {:ok, _} = Gyms.end_staff_membership(ctx.owner, ctx.gym.id, coach_row.staff_membership_id)

      [past | future] = series_rows(view.series_id)
      assert past.instructor_staff_membership_id == coach_row.staff_membership_id

      assert Enum.all?(
               future,
               &(is_nil(&1.instructor_staff_membership_id) and &1.instructor_released_at)
             )

      assert Repo.get!(ClassSeries, view.series_id).instructor_staff_membership_id == nil

      {:ok, released} = Gyms.get_class_occurrence(ctx.owner, ctx.gym.id, hd(future).id)
      assert released.needs_instructor and released.instructor == nil

      # Becoming front desk releases too.
      {:ok, _} =
        Gyms.change_staff_role(ctx.owner, ctx.gym.id, coach2_row.staff_membership_id, %{
          "role" => "front_desk"
        })

      assert stored_occurrence(solo.occurrence_id).instructor_staff_membership_id == nil

      assert [%AuditEvent{occurrence_count: 3}, %AuditEvent{occurrence_count: 1}] =
               Repo.all(
                 from(e in AuditEvent,
                   where: e.gym_id == ^ctx.gym.id and e.event_type == :class_instructor_released,
                   order_by: [asc: e.occurred_at]
                 )
               )
    end
  end

  describe "permissions and tenancy" do
    test "managers schedule; coaches cancel only their classes; front desk reads; outsiders and revoked staff get 404",
         ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager, "Agnieszka Lis")
      {coach, coach_row} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Tomasz Zieliński")
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk, "Michał Sowa")
      outsider = registered!("tt-outsider")

      mine =
        one_time!(manager, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "starts_at" => "2026-01-10T10:00:00+01:00",
          "instructor_staff_membership_id" => coach_row.staff_membership_id
        })

      theirs =
        one_time!(manager, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "starts_at" => "2026-01-10T12:00:00+01:00"
        })

      for user <- [coach, desk] do
        assert {:error, :forbidden} = at(ctx.gym, user, "2026-01-11T10:00:00+01:00", %{}, ctx)
        assert {:error, :forbidden} = Gyms.create_venue(user, session(user), ctx.gym.id, %{})
      end

      assert {:error, :forbidden} =
               Gyms.cancel_class_occurrence(
                 coach,
                 session(coach),
                 ctx.gym.id,
                 theirs.occurrence_id,
                 %{"expected_revision" => 1}
               )

      assert {:error, :forbidden} =
               Gyms.cancel_class_occurrence(
                 desk,
                 session(desk),
                 ctx.gym.id,
                 mine.occurrence_id,
                 %{"expected_revision" => 1}
               )

      {:ok, cancelled} =
        Gyms.cancel_class_occurrence(coach, session(coach), ctx.gym.id, mine.occurrence_id, %{
          "expected_revision" => 1
        })

      assert cancelled.status == :cancelled

      window = %{"from" => "2026-01-05T00:00:00Z", "to" => "2026-02-01T00:00:00Z"}

      for user <- [ctx.owner, manager, coach, desk] do
        assert {:ok, %{entries: [_, _]}} = Gyms.list_class_occurrences(user, ctx.gym.id, window)
      end

      assert {:error, :not_found} = Gyms.list_class_occurrences(outsider, ctx.gym.id, window)

      assert {:error, :not_found} =
               Gyms.get_class_occurrence(outsider, ctx.gym.id, theirs.occurrence_id)

      assert {:error, :not_found} =
               Gyms.create_venue(outsider, session(outsider), ctx.gym.id, %{})

      # Another gym's ids are unknown here.
      owner_b = registered!("tt-owner-b2")
      gym_b = completed_gym!(owner_b)

      assert {:error, :not_found} =
               Gyms.get_class_occurrence(owner_b, gym_b.id, theirs.occurrence_id)

      assert {:error, :not_found} = Gyms.get_venue(owner_b, gym_b.id, ctx.venue.venue_id)

      # Revoked: the next request is refused.
      manager_row =
        Repo.one!(
          from(m in SimpleFit.Gyms.StaffMembership,
            where: m.gym_id == ^ctx.gym.id and m.user_id == ^manager.id
          )
        )

      {:ok, _} = Gyms.end_staff_membership(ctx.owner, ctx.gym.id, manager_row.id)
      assert {:error, :not_found} = at(ctx.gym, manager, "2026-01-11T10:00:00+01:00", %{}, ctx)
      assert {:error, :not_found} = Gyms.list_class_occurrences(manager, ctx.gym.id, window)
    end

    test "the window is bounded and filters stay within the gym", ctx do
      assert {:error, changeset} =
               Gyms.list_class_occurrences(ctx.owner, ctx.gym.id, %{
                 "from" => "2026-01-01T00:00:00Z",
                 "to" => "2026-03-01T00:00:00Z"
               })

      assert codes(changeset) == %{"to" => ["out_of_range"]}

      assert {:error, %Ecto.Changeset{}} =
               Gyms.list_class_occurrences(ctx.owner, ctx.gym.id, %{
                 "from" => "2026-01-01",
                 "to" => "2026-01-02"
               })
    end

    test "a revoked session cannot write", ctx do
      session = session(ctx.owner)

      {1, _} =
        Repo.update_all(from(s in SimpleFit.Accounts.Session, where: s.id == ^session.id),
          set: [revoked_at: DateTime.utc_now(:second), revoked_reason: :logout]
        )

      assert {:error, :session_revoked} =
               Gyms.create_venue(ctx.owner, session, ctx.gym.id, %{})
    end
  end

  describe "first run and independence" do
    test "add_class completes on the first real class, not a template, and stays after a cancellation",
         ctx do
      item = fn ->
        ctx.gym.id
        |> then(&Repo.get!(SimpleFit.Gyms.Gym, &1))
        |> FirstRun.checklist()
        |> Enum.find(&(&1.key == :add_class))
      end

      assert item.().status == :available

      class =
        one_time!(ctx.owner, ctx.gym.id, %{
          "template_id" => ctx.template.template_id,
          "starts_at" => "2026-01-10T10:00:00+01:00"
        })

      assert item.().status == :completed

      {:ok, _} =
        Gyms.cancel_class_occurrence(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          class.occurrence_id,
          %{"expected_revision" => 1}
        )

      assert item.().status == :completed
    end

    test "classes create no training session, relationship, membership or staff row", ctx do
      counts = fn ->
        for table <-
              ~w(training_sessions coach_fighter_relationships gym_members gym_staff_memberships fighter_profiles coach_profiles),
            into: %{},
            do: {table, Repo.aggregate(table, :count)}
      end

      before = counts.()

      series!(ctx.owner, ctx.gym.id, %{
        "template_id" => ctx.template.template_id,
        "weekdays" => [1, 3, 5],
        "local_start_time" => "18:00",
        "starts_on" => "2026-01-05",
        "ends_on" => "2026-03-31"
      })

      one_time!(ctx.owner, ctx.gym.id, %{
        "template_id" => ctx.template.template_id,
        "starts_at" => "2026-01-10T10:00:00+01:00"
      })

      assert counts.() == before
    end

    test "every change is audited with ids and counts only", ctx do
      one_time!(ctx.owner, ctx.gym.id, %{
        "template_id" => ctx.template.template_id,
        "starts_at" => "2026-01-10T10:00:00+01:00"
      })

      types =
        Repo.all(
          from(e in AuditEvent,
            where: e.gym_id == ^ctx.gym.id,
            order_by: [asc: e.occurred_at],
            select: e.event_type
          )
        )

      assert Enum.take(types, -3) == [
               :venue_created,
               :class_template_created,
               :class_occurrence_created
             ]
    end
  end
end
