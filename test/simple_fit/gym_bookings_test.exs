defmodule SimpleFit.GymBookingsTest do
  @moduledoc """
  Gym class bookings and check-ins (SF-99) through `SimpleFit.Gyms`: member
  eligibility, idempotency, capacity, cancellation, the class and
  membership lifecycles (SF-97, SF-95), staff permissions, the roster's
  privacy, check-ins and the `first_check_in` milestone, the database
  guards, and independence from coaching, training and other gyms. The
  clock is frozen (SF-62).
  """

  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BookingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.Accounts.Session
  alias SimpleFit.{Clock, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, ClassBooking, ClassOccurrence, FirstRun}

  # Monday 5 January 2026, winter time in Warsaw (UTC+1).
  @now ~U[2026-01-05 12:00:00Z]
  # Wednesday 7 January 2026, 18:00 in Warsaw.
  @wednesday "2026-01-07T18:00:00+01:00"

  setup do
    Clock.freeze(@now)
    Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)

    owner = registered_as!(registered!("bk-owner"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    class = class!(owner, gym.id, @wednesday, 2)
    {marta, member} = member!(owner, gym.id, "Marta Kowalska")
    %{owner: owner, gym: gym, class: class, marta: marta, member: member}
  end

  defp events(gym_id, type),
    do:
      Repo.all(
        from(e in AuditEvent,
          where: e.gym_id == ^gym_id and e.event_type == ^type,
          order_by: [asc: e.occurred_at]
        )
      )

  defp session(user), do: live_session!(user)

  defp milestone(gym_id) do
    Repo.get!(SimpleFit.Gyms.Gym, gym_id)
    |> FirstRun.checklist()
    |> Enum.find(&(&1.key == :first_check_in))
    |> Map.fetch!(:status)
  end

  describe "a member's booking" do
    test "books one place: confirmed, counted, audited, and nothing else is created", ctx do
      counts = fn ->
        for table <-
              ~w(training_sessions coach_fighter_relationships fighter_profiles coach_profiles gym_staff_memberships),
            into: %{},
            do: {table, Repo.aggregate(table, :count)}
      end

      before = counts.()

      assert {:ok, {view, :created}} =
               book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)

      assert view.status == :confirmed
      assert view.booked_via == :member
      assert view.checked_in_at == nil
      assert view.class.occurrence_id == ctx.class.occurrence_id
      assert view.class.local_starts_at == ~N[2026-01-07 18:00:00]
      assert view.availability == %{capacity: 2, confirmed_count: 1, remaining_capacity: 1}
      assert confirmed(ctx.class.occurrence_id) == 1

      assert [%{class_booking_id: id, actor_user_id: actor}] =
               events(ctx.gym.id, :class_booking_created)

      assert id == view.booking_id
      assert actor == ctx.marta.id
      # No profile, relationship, training session, staff membership or money.
      assert counts.() == before
    end

    test "a replayed key returns the same booking and takes no place; a reused key is refused",
         ctx do
      key = Ecto.UUID.generate()

      assert {:ok, {first, :created}} =
               book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id, key)

      assert {:ok, {again, :existing}} =
               book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id, key)

      assert again.booking_id == first.booking_id
      assert confirmed(ctx.class.occurrence_id) == 1
      assert length(events(ctx.gym.id, :class_booking_created)) == 1

      other = class!(ctx.owner, ctx.gym.id, "2026-01-08T18:00:00+01:00", 5)

      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               book(ctx.marta, ctx.member.gym_member_id, other.occurrence_id, key)

      # A new key for the same class: one confirmed booking per member.
      assert {:error, {:conflict, %{class_booking: "already_booked"}}} =
               book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)
    end

    test "a full class is refused with its capacity; no waitlist is created", ctx do
      book!(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)
      {piotr, piotr_member} = member!(ctx.owner, ctx.gym.id, "Piotr Zając")
      book!(piotr, piotr_member.gym_member_id, ctx.class.occurrence_id)
      {ewa, ewa_member} = member!(ctx.owner, ctx.gym.id, "Ewa Malec")

      assert {:error, {:conflict, %{class_occurrence: "full", capacity: 2}}} =
               book(ewa, ewa_member.gym_member_id, ctx.class.occurrence_id)

      assert confirmed(ctx.class.occurrence_id) == 2
      assert length(booking_rows(ctx.class.occurrence_id)) == 2
    end

    test "cancelling frees the place, is final and idempotent; an old key never books again",
         ctx do
      key = Ecto.UUID.generate()

      {:ok, {booking, :created}} =
        book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id, key)

      session = session(ctx.marta)

      assert {:ok, cancelled} =
               Gyms.cancel_my_class_booking(ctx.marta, session, booking.booking_id)

      assert cancelled.status == :cancelled
      assert cancelled.cancel_reason == :member_cancelled
      assert confirmed(ctx.class.occurrence_id) == 0

      assert {:ok, ^cancelled} =
               Gyms.cancel_my_class_booking(ctx.marta, session, booking.booking_id)

      assert length(events(ctx.gym.id, :class_booking_cancelled)) == 1

      # The old creation key returns the cancelled booking: no new place.
      assert {:ok, {replayed, :existing}} =
               book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id, key)

      assert replayed.status == :cancelled
      assert confirmed(ctx.class.occurrence_id) == 0

      # Booking again is a new booking with a new key.
      assert {:ok, {rebooked, :created}} =
               book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)

      assert rebooked.booking_id != booking.booking_id
      assert confirmed(ctx.class.occurrence_id) == 1
    end

    test "only an active membership of the caller books, only in its own gym", ctx do
      code = join_code!(ctx.owner, ctx.gym.id)
      {requester, request} = requester!(code, "Rafał Tur")

      assert {:error, {:conflict, %{gym_member: "requested"}}} =
               book(requester, request.gym_member_id, ctx.class.occurrence_id)

      # Another user's membership id is not found, never borrowed.
      assert {:error, :not_found} =
               book(requester, ctx.member.gym_member_id, ctx.class.occurrence_id)

      # A class of another gym through this membership: not found.
      other_owner = registered!("bk-other")
      other_gym = completed_gym!(other_owner)
      other_class = class!(other_owner, other_gym.id, @wednesday, 5)

      assert {:error, :not_found} =
               book(ctx.marta, ctx.member.gym_member_id, other_class.occurrence_id)

      # An ended membership books nothing new.
      {:ok, _} =
        Gyms.leave_gym_membership(ctx.marta, session(ctx.marta), ctx.member.gym_member_id)

      assert {:error, {:conflict, %{gym_member: "ended"}}} =
               book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)
    end

    test "a cancelled or started class takes no booking", ctx do
      {:ok, _} =
        Gyms.cancel_class_occurrence(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          ctx.class.occurrence_id,
          %{
            "expected_revision" => 1
          }
        )

      assert {:error, {:conflict, %{class_occurrence: "cancelled"}}} =
               book(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)

      later = class!(ctx.owner, ctx.gym.id, "2026-01-09T18:00:00+01:00", 5)
      Clock.freeze(~U[2026-01-09 17:00:01Z])

      assert {:error, {:conflict, %{class_occurrence: "started"}}} =
               book(ctx.marta, ctx.member.gym_member_id, later.occurrence_id)
    end

    test "a revoked session books nothing", ctx do
      session = session(ctx.marta)

      Repo.update_all(from(s in Session, where: s.id == ^session.id),
        set: [revoked_at: DateTime.utc_now(:second), revoked_reason: :logout]
      )

      assert {:error, :session_revoked} =
               Gyms.book_class(ctx.marta, session, ctx.member.gym_member_id, %{
                 "occurrence_id" => ctx.class.occurrence_id,
                 "client_request_id" => Ecto.UUID.generate()
               })

      assert confirmed(ctx.class.occurrence_id) == 0
    end

    test "invalid and unknown fields are 422", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Gyms.book_class(ctx.marta, session(ctx.marta), ctx.member.gym_member_id, %{
                 "occurrence_id" => "nope",
                 "client_request_id" => Ecto.UUID.generate()
               })

      assert {:error, %Ecto.Changeset{} = changeset} =
               Gyms.book_class(ctx.marta, session(ctx.marta), ctx.member.gym_member_id, %{
                 "occurrence_id" => ctx.class.occurrence_id,
                 "client_request_id" => Ecto.UUID.generate(),
                 "gym_member_id" => ctx.member.gym_member_id
               })

      assert List.keymember?(changeset.errors, "gym_member_id", 0)
    end

    test "the member's classes show the places left and their own booking only", ctx do
      book!(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)
      {piotr, piotr_member} = member!(ctx.owner, ctx.gym.id, "Piotr Zając")

      assert {:ok, %{entries: [entry]}} =
               Gyms.list_member_classes(piotr, piotr_member.gym_member_id, %{
                 "from" => "2026-01-05T00:00:00Z",
                 "to" => "2026-01-12T00:00:00Z"
               })

      assert entry.remaining_capacity == 1
      assert entry.booking == nil
      refute Map.has_key?(entry, :gym_id)

      assert {:ok, %{entries: [mine]}} =
               Gyms.list_member_classes(ctx.marta, ctx.member.gym_member_id, %{
                 "from" => "2026-01-05T00:00:00Z",
                 "to" => "2026-01-12T00:00:00Z"
               })

      assert mine.booking.status == :confirmed

      assert {:ok, %{entries: [own]}} = Gyms.list_my_class_bookings(ctx.marta, %{})
      assert {:ok, %{entries: []}} = Gyms.list_my_class_bookings(piotr, %{})
      assert {:ok, _} = Gyms.get_my_class_booking(ctx.marta, own.booking_id)
      assert {:error, :not_found} = Gyms.get_my_class_booking(piotr, own.booking_id)
    end
  end

  describe "the class and membership lifecycles" do
    test "cancelling a class releases its bookings in the same transaction", ctx do
      booking = book!(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)

      {:ok, _} =
        Gyms.cancel_class_occurrence(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          ctx.class.occurrence_id,
          %{
            "expected_revision" => 1
          }
        )

      assert %ClassBooking{status: :cancelled, cancel_reason: :occurrence_cancelled} =
               Repo.get!(ClassBooking, booking.booking_id)

      assert [%{booking_count: 1}] = events(ctx.gym.id, :class_bookings_released)
    end

    test "a class keeps at least as many places as its confirmed bookings", ctx do
      book!(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)
      {piotr, piotr_member} = member!(ctx.owner, ctx.gym.id, "Piotr Zając")
      book!(piotr, piotr_member.gym_member_id, ctx.class.occurrence_id)

      assert {:error,
              {:conflict, %{class_occurrence: "capacity_below_bookings", confirmed_bookings: 2}}} =
               Gyms.update_class_occurrence(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 ctx.class.occurrence_id,
                 %{
                   "expected_revision" => 1,
                   "capacity" => 1
                 }
               )

      assert {:ok, %{capacity: 3}} =
               Gyms.update_class_occurrence(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 ctx.class.occurrence_id,
                 %{
                   "expected_revision" => 1,
                   "capacity" => 3
                 }
               )
    end

    test "a series keeps its booked places, and its cancellation or change releases them",
         ctx do
      template =
        SimpleFit.TimetableHelpers.template!(ctx.owner, ctx.gym.id, %{
          "default_venue_id" => SimpleFit.TimetableHelpers.venue!(ctx.owner, ctx.gym.id).venue_id
        })

      series =
        SimpleFit.TimetableHelpers.series!(ctx.owner, ctx.gym.id, %{
          "template_id" => template.template_id,
          "weekdays" => [1, 3],
          "local_start_time" => "07:00",
          "starts_on" => "2026-01-12",
          "ends_on" => "2026-01-21",
          "capacity" => 3
        })

      [monday, wednesday | _] = SimpleFit.TimetableHelpers.series_rows(series.series_id)
      book!(ctx.marta, ctx.member.gym_member_id, monday.id)
      {piotr, piotr_member} = member!(ctx.owner, ctx.gym.id, "Piotr Zając")
      book!(piotr, piotr_member.gym_member_id, monday.id)
      wed = book!(ctx.marta, ctx.member.gym_member_id, wednesday.id)

      assert {:error,
              {:conflict, %{class_series: "capacity_below_bookings", local_dates: ["2026-01-12"]}}} =
               Gyms.update_class_series(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 series.series_id,
                 %{
                   "expected_revision" => 1,
                   "capacity" => 1
                 }
               )

      # Wednesdays leave the rule: their bookings are released with them.
      {:ok, _} =
        Gyms.update_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, series.series_id, %{
          "expected_revision" => 1,
          "weekdays" => [1]
        })

      assert %{status: :cancelled, cancel_reason: :occurrence_cancelled} =
               Repo.get!(ClassBooking, wed.booking_id)

      assert confirmed(monday.id) == 2

      {:ok, _} =
        Gyms.cancel_class_series(ctx.owner, session(ctx.owner), ctx.gym.id, series.series_id, %{
          "expected_revision" => 2
        })

      assert confirmed(monday.id) == 0
      assert %{status: :cancelled} = Repo.get!(ClassOccurrence, monday.id)
    end

    test "an ending membership releases its future bookings, never another gym's", ctx do
      future = book!(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)

      other_owner = registered!("bk-other")
      other_gym = completed_gym!(other_owner)
      other_class = class!(other_owner, other_gym.id, @wednesday, 5)
      code = join_code!(other_owner, other_gym.id)
      {:ok, request, :created} = join(ctx.marta, code)

      {:ok, other_member} =
        Gyms.approve_join_request(other_owner, other_gym.id, request.gym_member_id)

      # Different time: the same person may book both.
      elsewhere = book!(ctx.marta, other_member.gym_member_id, other_class.occurrence_id)

      {:ok, _} = Gyms.remove_member(ctx.owner, ctx.gym.id, ctx.member.gym_member_id)

      assert %{status: :cancelled, cancel_reason: :membership_ended} =
               Repo.get!(ClassBooking, future.booking_id)

      assert %{status: :confirmed} = Repo.get!(ClassBooking, elsewhere.booking_id)
      assert [%{booking_count: 1}] = events(ctx.gym.id, :class_bookings_released)
      assert events(other_gym.id, :class_bookings_released) == []
    end
  end

  describe "staff" do
    setup ctx do
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk, "Michał Sowa")
      {coach, coach_row} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Tomasz Zieliński")
      %{desk: desk, coach: coach, coach_row: coach_row}
    end

    test "front desk books and cancels for a member; a coach may not", ctx do
      attrs = %{
        "gym_member_id" => ctx.member.gym_member_id,
        "client_request_id" => Ecto.UUID.generate()
      }

      assert {:ok, {booked, :created}} =
               Gyms.book_class_for_member(
                 ctx.desk,
                 session(ctx.desk),
                 ctx.gym.id,
                 ctx.class.occurrence_id,
                 attrs
               )

      assert booked.booked_via == :staff
      assert booked.name == "Marta K."
      assert booked.summary.confirmed_count == 1

      assert {:error, :forbidden} =
               Gyms.book_class_for_member(
                 ctx.coach,
                 session(ctx.coach),
                 ctx.gym.id,
                 ctx.class.occurrence_id,
                 %{
                   attrs
                   | "client_request_id" => Ecto.UUID.generate()
                 }
               )

      assert {:error, %Ecto.Changeset{}} =
               Gyms.book_class_for_member(
                 ctx.desk,
                 session(ctx.desk),
                 ctx.gym.id,
                 ctx.class.occurrence_id,
                 %{
                   "gym_member_id" => Ecto.UUID.generate(),
                   "client_request_id" => Ecto.UUID.generate()
                 }
               )

      assert {:ok, %{status: :cancelled, cancel_reason: :staff_cancelled}} =
               Gyms.cancel_class_booking(
                 ctx.desk,
                 session(ctx.desk),
                 ctx.gym.id,
                 booked.booking_id
               )

      assert {:error, :forbidden} =
               Gyms.cancel_class_booking(
                 ctx.coach,
                 session(ctx.coach),
                 ctx.gym.id,
                 booked.booking_id
               )
    end

    test "the roster shows short names and booking facts; a coach sees only their own classes",
         ctx do
      book!(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)

      assert {:ok, %{summary: summary, entries: [entry]}} =
               Gyms.class_roster(ctx.desk, ctx.gym.id, ctx.class.occurrence_id, %{})

      assert summary == %{
               capacity: 2,
               confirmed_count: 1,
               remaining_capacity: 1,
               checked_in_count: 0
             }

      assert entry.name == "Marta K."

      assert Map.keys(entry) |> Enum.sort() ==
               ~w(booked_via booking_id cancel_reason cancelled_at checked_in_at confirmed_at gym_member_id name status)a

      assert {:error, :forbidden} =
               Gyms.class_roster(ctx.coach, ctx.gym.id, ctx.class.occurrence_id, %{})

      own =
        class!(ctx.owner, ctx.gym.id, "2026-01-10T10:00:00+01:00", 5, %{
          "instructor_staff_membership_id" => ctx.coach_row.staff_membership_id
        })

      assert {:ok, %{entries: []}} =
               Gyms.class_roster(ctx.coach, ctx.gym.id, own.occurrence_id, %{})

      stranger = registered!("bk-stranger")

      assert {:error, :not_found} =
               Gyms.class_roster(stranger, ctx.gym.id, ctx.class.occurrence_id, %{})
    end

    test "check-in: on the class's day only, once, never for a cancelled booking; it completes first_check_in",
         ctx do
      booking = book!(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)
      assert milestone(ctx.gym.id) == :available

      assert {:error, {:conflict, %{class_occurrence: "not_today"}}} =
               check_in(ctx.desk, ctx.gym.id, booking.booking_id)

      # Wednesday 17:30 in Warsaw.
      Clock.freeze(~U[2026-01-07 16:30:00Z])
      assert {:ok, {first, :created}} = check_in(ctx.coach, ctx.gym.id, booking.booking_id)
      assert {:ok, {again, :existing}} = check_in(ctx.desk, ctx.gym.id, booking.booking_id)
      assert again.check_in_id == first.check_in_id
      assert check_ins(ctx.class.occurrence_id) == 1
      assert length(events(ctx.gym.id, :class_check_in_recorded)) == 1
      assert milestone(ctx.gym.id) == :completed

      # Attended: no longer cancelled by the member or the gym.
      assert {:error, {:conflict, %{class_booking: "checked_in"}}} =
               Gyms.cancel_my_class_booking(ctx.marta, session(ctx.marta), booking.booking_id)

      {piotr, piotr_member} = member!(ctx.owner, ctx.gym.id, "Piotr Zając")
      other = book!(piotr, piotr_member.gym_member_id, ctx.class.occurrence_id)
      {:ok, _} = Gyms.cancel_my_class_booking(piotr, session(piotr), other.booking_id)

      assert {:error, {:conflict, %{class_booking: "cancelled"}}} =
               check_in(ctx.desk, ctx.gym.id, other.booking_id)

      assert {:ok, %{summary: %{checked_in_count: 1}}} =
               Gyms.class_roster(ctx.owner, ctx.gym.id, ctx.class.occurrence_id, %{})

      # Another gym's checklist is untouched.
      other_gym = completed_gym!(registered!("bk-other"))
      assert milestone(other_gym.id) == :available
    end
  end

  describe "the database guards" do
    test "no booking beyond the capacity, in a cancelled class or for an inactive member", ctx do
      book!(ctx.marta, ctx.member.gym_member_id, ctx.class.occurrence_id)
      {piotr, piotr_member} = member!(ctx.owner, ctx.gym.id, "Piotr Zając")
      book!(piotr, piotr_member.gym_member_id, ctx.class.occurrence_id)
      {_ewa, ewa_member} = member!(ctx.owner, ctx.gym.id, "Ewa Malec")

      row = fn member_id ->
        %ClassBooking{
          gym_id: ctx.gym.id,
          occurrence_id: ctx.class.occurrence_id,
          gym_member_id: member_id,
          booked_via: :staff,
          client_request_id: Ecto.UUID.generate(),
          confirmed_at: DateTime.utc_now()
        }
      end

      error =
        assert_raise Ecto.ConstraintError, fn -> Repo.insert!(row.(ewa_member.gym_member_id)) end

      assert error.constraint == "gym_class_bookings_capacity"

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(from(o in ClassOccurrence, where: o.id == ^ctx.class.occurrence_id),
            set: [capacity: 1]
          )
        end

      assert error.postgres.constraint == "gym_class_occurrences_capacity_bookings"

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(from(o in ClassOccurrence, where: o.id == ^ctx.class.occurrence_id),
            set: [
              status: "cancelled",
              cancelled_at: DateTime.utc_now(),
              cancel_reason: "cancelled"
            ]
          )
        end

      assert error.postgres.constraint == "gym_class_occurrences_cancel_bookings"

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(
            from(b in ClassBooking, where: b.gym_member_id == ^piotr_member.gym_member_id),
            set: [occurrence_id: Ecto.UUID.generate()]
          )
        end

      assert error.postgres.code in [:check_violation, :foreign_key_violation]
      assert piotr
    end
  end
end
