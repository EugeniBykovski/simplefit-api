defmodule SimpleFit.GymBookingsRaceTest do
  @moduledoc """
  Gym class bookings and check-ins under true concurrency and real commits
  (SF-99), on separate connections outside the SQL sandbox: the occurrence
  row lock, the gym row lock shared with SF-97 and SF-95 writes, the
  partial unique index, the idempotency index and the database's capacity
  guard are exercised for real. Every test checks the final committed
  state (rows, counts, audit events). Committed rows are removed afterwards
  (through the purge switch).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BookingHelpers
  import SimpleFit.GymHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.{Clock, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, ClassBooking, ClassCheckIn, ClassOccurrence, Gym}
  alias SimpleFit.Gyms.StaffMembership

  # Monday 5 January 2026, 13:00 in Warsaw; the classes below are today at
  # 19:00 local (bookable and checked in today).
  @now ~U[2026-01-05 12:00:00Z]
  @today "2026-01-05T19:00:00+01:00"

  setup do
    Sandbox.mode(Repo, :auto)
    Clock.freeze(@now)
    reset_limits()
    {:ok, users} = Agent.start(fn -> [] end)
    # Joining and staff invitations enqueue emails, committed here: removed after.
    first_job = Repo.one(from(j in Oban.Job, select: max(j.id))) || 0

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(j in Oban.Job, where: j.id > ^first_job))
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
      Clock.unfreeze()
      Sandbox.mode(Repo, :manual)
    end)

    owner = track(users, registered_as!(registered!("bkrace-owner"), "Yauheni Bykovski"))
    gym = completed_gym!(owner)
    %{users: users, owner: owner, gym: gym, code: join_code!(owner, gym.id)}
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

  # `n` active members of the gym: {user, gym_member_id}.
  defp members(ctx, n) do
    for i <- 1..n do
      {user, request} = requester!(ctx.code, "Member #{i} Race")
      track(ctx.users, user)
      {:ok, _} = Gyms.approve_join_request(ctx.owner, ctx.gym.id, request.gym_member_id)
      {user, request.gym_member_id}
    end
  end

  defp events(gym_id, type),
    do:
      Repo.aggregate(
        from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type),
        :count
      )

  defp created(results), do: Enum.count(results, &match?({:ok, {_, :created}}, &1))

  defp count(results, pattern), do: Enum.count(results, &(&1 == pattern))

  test "capacity 1: 20 members race for the last place, exactly one gets it", ctx do
    class = class!(ctx.owner, ctx.gym.id, @today, 1)
    racers = members(ctx, 20)

    results =
      concurrently(
        for {user, member_id} <- racers,
            do: fn -> book(user, member_id, class.occurrence_id) end
      )

    assert created(results) == 1
    assert count(results, {:error, {:conflict, %{class_occurrence: "full", capacity: 1}}}) == 19
    assert confirmed(class.occurrence_id) == 1
    assert length(booking_rows(class.occurrence_id)) == 1
    assert events(ctx.gym.id, :class_booking_created) == 1
  end

  test "capacity 5: 30 members race, exactly five places are taken", ctx do
    class = class!(ctx.owner, ctx.gym.id, @today, 5)
    racers = members(ctx, 30)

    results =
      concurrently(
        for {user, member_id} <- racers,
            do: fn -> book(user, member_id, class.occurrence_id) end
      )

    assert created(results) == 5
    assert count(results, {:error, {:conflict, %{class_occurrence: "full", capacity: 5}}}) == 25
    assert confirmed(class.occurrence_id) == 5
    assert events(ctx.gym.id, :class_booking_created) == 5
  end

  test "one member: the same request 20 times is one booking; 20 keys are one booking too", ctx do
    class = class!(ctx.owner, ctx.gym.id, @today, 5)
    [{user, member_id}] = members(ctx, 1)
    key = Ecto.UUID.generate()

    same =
      concurrently(for _ <- 1..20, do: fn -> book(user, member_id, class.occurrence_id, key) end)

    assert created(same) == 1
    assert Enum.count(same, &match?({:ok, {_, :existing}}, &1)) == 19
    assert length(booking_rows(class.occurrence_id)) == 1

    other = class!(ctx.owner, ctx.gym.id, "2026-01-05T21:00:00+01:00", 5)

    keys =
      concurrently(for _ <- 1..20, do: fn -> book(user, member_id, other.occurrence_id) end)

    assert created(keys) == 1
    assert count(keys, {:error, {:conflict, %{class_booking: "already_booked"}}}) == 19
    assert confirmed(other.occurrence_id) == 1
    assert events(ctx.gym.id, :class_booking_created) == 2
  end

  test "a booking racing another member's cancellation never exceeds the capacity", ctx do
    for _round <- 1..5 do
      class = class!(ctx.owner, ctx.gym.id, @today, 1)
      [{holder, holder_member}, {racer, racer_member}] = members(ctx, 2)
      held = book!(holder, holder_member, class.occurrence_id)

      [cancelled, booked] =
        concurrently([
          fn -> Gyms.cancel_my_class_booking(holder, live_session!(holder), held.booking_id) end,
          fn -> book(racer, racer_member, class.occurrence_id) end
        ])

      assert {:ok, %{status: :cancelled}} = cancelled

      assert match?({:ok, {_, :created}}, booked) or
               booked == {:error, {:conflict, %{class_occurrence: "full", capacity: 1}}}

      assert confirmed(class.occurrence_id) == if(match?({:ok, _}, booked), do: 1, else: 0)
    end
  end

  test "bookings racing the class's cancellation: none survives on a cancelled class", ctx do
    class = class!(ctx.owner, ctx.gym.id, @today, 10)
    racers = members(ctx, 8)

    [cancel | bookings] =
      concurrently([
        fn ->
          Gyms.cancel_class_occurrence(
            ctx.owner,
            live_session!(ctx.owner),
            ctx.gym.id,
            class.occurrence_id,
            %{"expected_revision" => 1}
          )
        end
        | for(
            {user, member_id} <- racers,
            do: fn -> book(user, member_id, class.occurrence_id) end
          )
      ])

    assert {:ok, %{status: :cancelled}} = cancel
    assert confirmed(class.occurrence_id) == 0
    booked = created(bookings)

    assert count(bookings, {:error, {:conflict, %{class_occurrence: "cancelled"}}}) ==
             8 - booked

    # Everything booked before the cancellation was released with it.
    assert Repo.aggregate(
             from(b in ClassBooking,
               where:
                 b.occurrence_id == ^class.occurrence_id and
                   b.cancel_reason == :occurrence_cancelled
             ),
             :count
           ) == booked
  end

  test "bookings racing a series cancellation: no confirmed place is left in it", ctx do
    venue = SimpleFit.TimetableHelpers.venue!(ctx.owner, ctx.gym.id)

    template =
      SimpleFit.TimetableHelpers.template!(ctx.owner, ctx.gym.id, %{
        "default_venue_id" => venue.venue_id
      })

    series =
      SimpleFit.TimetableHelpers.series!(ctx.owner, ctx.gym.id, %{
        "template_id" => template.template_id,
        "weekdays" => [1, 3, 5],
        "local_start_time" => "19:00",
        "starts_on" => "2026-01-05",
        "ends_on" => "2026-01-16"
      })

    rows = SimpleFit.TimetableHelpers.series_rows(series.series_id)
    racers = members(ctx, 6)

    [cancel | _bookings] =
      concurrently([
        fn ->
          Gyms.cancel_class_series(
            ctx.owner,
            live_session!(ctx.owner),
            ctx.gym.id,
            series.series_id,
            %{"expected_revision" => 1}
          )
        end
        | for(
            {{user, member_id}, row} <- Enum.zip(racers, Stream.cycle(rows)),
            do: fn -> book(user, member_id, row.id) end
          )
      ])

    assert {:ok, %{status: :cancelled}} = cancel

    for row <- rows do
      assert confirmed(row.id) == 0
      assert %{status: :cancelled} = Repo.get!(ClassOccurrence, row.id)
    end
  end

  test "bookings racing a capacity reduction: the capacity always holds its bookings", ctx do
    for _round <- 1..3 do
      class = class!(ctx.owner, ctx.gym.id, @today, 6)
      racers = members(ctx, 6)

      [reduce | _bookings] =
        concurrently([
          fn ->
            Gyms.update_class_occurrence(
              ctx.owner,
              live_session!(ctx.owner),
              ctx.gym.id,
              class.occurrence_id,
              %{"expected_revision" => 1, "capacity" => 2}
            )
          end
          | for(
              {user, member_id} <- racers,
              do: fn -> book(user, member_id, class.occurrence_id) end
            )
        ])

      occurrence = Repo.get!(ClassOccurrence, class.occurrence_id)
      assert confirmed(class.occurrence_id) <= occurrence.capacity

      case reduce do
        {:ok, _} ->
          assert occurrence.capacity == 2

        {:error, {:conflict, %{class_occurrence: "capacity_below_bookings"}}} ->
          assert occurrence.capacity == 6
      end
    end
  end

  test "bookings racing the member's removal: no confirmed future place outlives it", ctx do
    classes =
      for hour <- 15..20, do: class!(ctx.owner, ctx.gym.id, "2026-01-05T#{hour}:00:00+01:00", 5)

    [{user, member_id}] = members(ctx, 1)

    [removed | _bookings] =
      concurrently([
        fn -> Gyms.remove_member(ctx.owner, ctx.gym.id, member_id) end
        | for(class <- classes, do: fn -> book(user, member_id, class.occurrence_id) end)
      ])

    assert {:ok, %{status: :ended}} = removed

    assert Repo.aggregate(
             from(b in ClassBooking,
               where: b.gym_member_id == ^member_id and b.status == :confirmed
             ),
             :count
           ) == 0
  end

  test "a booking racing a session revocation: it is booked before or refused after", ctx do
    for _round <- 1..5 do
      class = class!(ctx.owner, ctx.gym.id, @today, 5)
      [{user, member_id}] = members(ctx, 1)
      session = live_session!(user)

      [booked, _revoked] =
        concurrently([
          fn ->
            Gyms.book_class(user, session, member_id, %{
              "occurrence_id" => class.occurrence_id,
              "client_request_id" => Ecto.UUID.generate()
            })
          end,
          fn ->
            Repo.update_all(from(s in Session, where: s.id == ^session.id),
              set: [revoked_at: DateTime.utc_now(:second), revoked_reason: :logout]
            )
          end
        ])

      assert match?({:ok, {_, :created}}, booked) or booked == {:error, :session_revoked}
      assert confirmed(class.occurrence_id) == if(match?({:ok, _}, booked), do: 1, else: 0)
    end
  end

  test "two gyms keep independent capacities under concurrency", ctx do
    other_owner = track(ctx.users, registered_as!(registered!("bkrace-other"), "Ola Nowak"))
    other_gym = completed_gym!(other_owner)

    other = %{
      ctx
      | owner: other_owner,
        gym: other_gym,
        code: join_code!(other_owner, other_gym.id)
    }

    here = class!(ctx.owner, ctx.gym.id, @today, 1)
    there = class!(other_owner, other_gym.id, @today, 1)
    a = members(ctx, 5)
    b = members(other, 5)

    results =
      concurrently(
        for({user, member_id} <- a, do: fn -> book(user, member_id, here.occurrence_id) end) ++
          for({user, member_id} <- b, do: fn -> book(user, member_id, there.occurrence_id) end)
      )

    assert created(results) == 2
    assert confirmed(here.occurrence_id) == 1
    assert confirmed(there.occurrence_id) == 1

    # Gym A's membership never books Gym B's class.
    [{user, member_id} | _] = a
    assert {:error, :not_found} = book(user, member_id, there.occurrence_id)
  end

  test "20 concurrent check-ins of one booking are one check-in and one event", ctx do
    class = class!(ctx.owner, ctx.gym.id, @today, 5)
    [{user, member_id}] = members(ctx, 1)
    booking = book!(user, member_id, class.occurrence_id)

    results =
      concurrently(
        for _ <- 1..20, do: fn -> check_in(ctx.owner, ctx.gym.id, booking.booking_id) end
      )

    assert created(results) == 1
    assert Enum.count(results, &match?({:ok, {_, :existing}}, &1)) == 19
    assert check_ins(class.occurrence_id) == 1
    assert events(ctx.gym.id, :class_check_in_recorded) == 1
  end

  test "a check-in racing the booking's cancellation: one of them wins, never both", ctx do
    for _round <- 1..5 do
      class = class!(ctx.owner, ctx.gym.id, @today, 5)
      [{user, member_id}] = members(ctx, 1)
      booking = book!(user, member_id, class.occurrence_id)

      [checked, cancelled] =
        concurrently([
          fn -> check_in(ctx.owner, ctx.gym.id, booking.booking_id) end,
          fn -> Gyms.cancel_my_class_booking(user, live_session!(user), booking.booking_id) end
        ])

      stored = Repo.get!(ClassBooking, booking.booking_id)
      present = Repo.exists?(from(c in ClassCheckIn, where: c.booking_id == ^booking.booking_id))

      case {checked, cancelled} do
        {{:ok, {_, :created}}, {:error, {:conflict, %{class_booking: "checked_in"}}}} ->
          assert present and stored.status == :confirmed

        {{:error, {:conflict, %{class_booking: "cancelled"}}}, {:ok, _}} ->
          refute present
          assert stored.status == :cancelled
      end
    end
  end

  test "a check-in racing the class's cancellation and a staff revocation stays consistent",
       ctx do
    {desk, desk_row} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk, "Michał Sowa")
    track(ctx.users, desk)
    class = class!(ctx.owner, ctx.gym.id, @today, 5)
    racers = members(ctx, 2)
    [one, two] = for {user, member_id} <- racers, do: book!(user, member_id, class.occurrence_id)

    [checked, cancel, revoked, by_desk] =
      concurrently([
        fn -> check_in(ctx.owner, ctx.gym.id, one.booking_id) end,
        fn ->
          Gyms.cancel_class_occurrence(
            ctx.owner,
            live_session!(ctx.owner),
            ctx.gym.id,
            class.occurrence_id,
            %{"expected_revision" => 1}
          )
        end,
        fn ->
          Gyms.revoke_staff_membership(ctx.owner, ctx.gym.id, desk_row.staff_membership_id)
        end,
        fn -> check_in(desk, ctx.gym.id, two.booking_id) end
      ])

    assert {:ok, _} = cancel
    assert {:ok, _} = revoked
    assert confirmed(class.occurrence_id) == 0

    # A check-in exists only where it answered success; a revoked desk gets 404.
    for {result, booking} <- [{checked, one}, {by_desk, two}] do
      present = Repo.exists?(from(c in ClassCheckIn, where: c.booking_id == ^booking.booking_id))
      assert present == match?({:ok, {_, :created}}, result)
    end

    assert match?({:ok, _}, by_desk) or
             by_desk in [
               {:error, :not_found},
               {:error, {:conflict, %{class_occurrence: "cancelled"}}},
               {:error, {:conflict, %{class_booking: "cancelled"}}}
             ]
  end
end
