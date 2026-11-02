defmodule SimpleFit.Gyms.Bookings do
  @moduledoc """
  Class bookings, rosters and check-ins (SF-99; ADR 0026 amendment SF-99;
  SF-82 01 §4.7–4.8, 02 §4, 08 T7). Internal to `SimpleFit.Gyms`.

  ## Who

    * **A member** (an *active* gym membership of the session's own user,
      SF-95; no Fighter or Coach profile needed) books a place in a class of
      that gym, reads and cancels their own bookings, and lists the gym's
      classes with the seats left and their own booking. A requested, ended,
      rejected or cancelled membership books nothing (`409 gym_member`).
    * **Staff:** owner, managers and front desk book and cancel for an
      active member (`book_for_member`); every staff role reads a class's
      roster (`view_rosters`; a coach only for classes they instruct) and
      records a check-in (`record_check_in`).

  ## Rules (the minimum approved lifecycle)

    * A class is bookable while it is scheduled and has not started; a
      booking is cancelled until the class starts. There is no other window,
      no waitlist, no capacity override, no no-show and no penalty (FUTURE,
      ADR amendment).
    * One confirmed booking per member and class; `confirmed bookings <=
      capacity`, counted under the occurrence row lock (and again by the
      database's guard). A cancelled booking holds no seat and is final:
      booking the class again is a new booking with a new key.
    * A `client_request_id` names one logical booking for ever: the same key
      again returns that booking (`200`), even after it was cancelled, and
      consumes nothing; the key used for another member or class is `409
      client_request_id: reused`.
    * A check-in needs a confirmed booking of a scheduled class, on the
      class's own local day (in its venue's zone). One per booking: a repeat
      returns the same event. A checked-in booking is no longer cancelled.
    * The class's cancellation (SF-97) releases its confirmed bookings
      (`occurrence_cancelled`); a membership that ends (SF-95) releases the
      member's bookings of classes still to come that have no check-in
      (`membership_ended`). Both in the same transaction as their cause.

  ## Locks

  A member's booking or cancellation holds the session (`FOR SHARE`), the
  gym row (`FOR SHARE`), the member row (`FOR SHARE`), then the occurrence
  row (`FOR UPDATE`) and the booking. Staff writes take the SF-97 write
  order (`Schedule.write/5`: session, gym `FOR UPDATE`, staff membership),
  then the member, the occurrence and the booking. So bookings of one class
  serialize on its row; a class change, cancellation, staff booking,
  check-in or member removal (gym `FOR UPDATE`) commits entirely before or
  after a member's booking; and the locks are always taken in the order
  session → gym → staff membership → member → occurrence → booking.

  ## Privacy

  A member sees only their own bookings; the roster shows staff the
  member's short name, booking status and times and the check-in time:
  never an email, user id, profile, other gym or training data (D-G06).
  Nothing here logs a name, an id or a token.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.{Accounts, Clock, RateLimit, Repo, Scheduling}
  alias SimpleFit.Accounts.{Session, User}

  alias SimpleFit.Gyms.{
    Access,
    Audit,
    ClassBooking,
    ClassCheckIn,
    ClassOccurrence,
    Gym,
    Member,
    Members,
    MemberSecrets,
    Paging,
    Schedule,
    Timetable
  }

  @unlogged [log: false]
  @booking_fields ["occurrence_id", "client_request_id"]
  @staff_booking_fields ["gym_member_id", "client_request_id"]

  @type error ::
          :not_found
          | :forbidden
          | :session_revoked
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | Changeset.t()

  ## Member side

  @doc """
  The classes of the gym of the caller's own active membership `member_id`
  in a window (params: `from`, `to` (at most 31 days), optional `status`,
  `limit`, `cursor`), by start time, each with its seats left and the
  caller's own booking of it (if any).
  """
  @spec list_classes(User.t(), term(), map()) :: {:ok, map()} | {:error, error()}
  def list_classes(%User{} = user, member_id, params) when is_map(params) do
    with {:ok, member} <- own_active(user, member_id),
         {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, [:scheduled, :cancelled]),
         {:ok, %{from: from, to: to}} <- Timetable.class_window(params) do
      {rows, next} =
        from(o in ClassOccurrence,
          where: o.gym_id == ^member.gym_id and o.starts_at >= ^from and o.starts_at < ^to,
          order_by: [asc: o.starts_at, asc: o.id],
          limit: ^(limit + 1)
        )
        |> then(&if(status, do: from(o in &1, where: o.status == ^status), else: &1))
        |> Paging.seek(cursor, :starts_at, :asc)
        |> Repo.all(@unlogged)
        |> Paging.page(limit, :starts_at)

      {:ok, %{entries: member_classes(rows, member), next_cursor: next}}
    end
  end

  @doc """
  Books a place for the caller in a class of the gym of their own active
  membership `member_id` (`attrs`: `occurrence_id`, `client_request_id`).
  `{:ok, {view, :created | :existing}}`.
  """
  @spec book(User.t(), Session.t(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, error()}
  def book(%User{} = user, %Session{} = session, member_id, attrs) when is_map(attrs) do
    with {:ok, params} <- booking_params(attrs, @booking_fields, :occurrence_id) do
      Repo.transaction(fn -> book_in(user, session, member_id, params) end, @unlogged)
    end
    |> tap(&emit(:class_booking_created, &1))
  end

  defp book_in(user, session, member_id, params) do
    with :ok <- Members.held(Accounts.hold_active_session(user, session)),
         {:ok, member} <- lock_own_member(user, member_id),
         {:ok, result} <- place(member, params.occurrence_id, params, :member, user) do
      {own_view(result.booking, result.occurrence), result.outcome}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  The caller's own bookings, every gym, newest first (params: `status`
  `confirmed` or `cancelled`, `limit`, `cursor`).
  """
  @spec list_mine(User.t(), map()) :: {:ok, map()} | {:error, error()}
  def list_mine(%User{id: user_id}, params) when is_binary(user_id) and is_map(params) do
    with {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, [:confirmed, :cancelled]) do
      {rows, next} =
        from(b in ClassBooking,
          join: m in Member,
          on: m.id == b.gym_member_id,
          where: m.user_id == ^user_id,
          order_by: [desc: b.inserted_at, desc: b.id],
          limit: ^(limit + 1)
        )
        |> then(&if(status, do: from(b in &1, where: b.status == ^status), else: &1))
        |> Paging.seek(cursor, :inserted_at, :desc)
        |> Repo.all(@unlogged)
        |> Paging.page(limit, :inserted_at)

      {:ok, %{entries: own_views(rows), next_cursor: next}}
    end
  end

  @doc "One of the caller's own bookings (`:not_found` for anyone else's)."
  @spec get_mine(User.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def get_mine(%User{} = user, booking_id) do
    case own_booking(user, booking_id) do
      %ClassBooking{} = booking -> {:ok, hd(own_views([booking]))}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Cancels the caller's own booking until its class starts
  (`member_cancelled`). Cancelling it again returns it unchanged.
  """
  @spec cancel_mine(User.t(), Session.t(), term()) :: {:ok, map()} | {:error, error()}
  def cancel_mine(%User{} = user, %Session{} = session, booking_id) do
    Repo.transaction(
      fn ->
        with :ok <- Members.held(Accounts.hold_active_session(user, session)),
             %ClassBooking{} = found <-
               own_booking(user, booking_id) || {:error, :not_found},
             %Gym{} <- Access.lock_gym_shared!(found.gym_id),
             %ClassBooking{} = booking <- lock_booking(found.gym_id, found.id),
             :ok <- limit(user),
             {:ok, cancelled} <- cancel(booking, :member_cancelled, user.id) do
          hd(own_views([cancelled]))
        else
          {:error, reason} -> Repo.rollback(reason)
          nil -> Repo.rollback(:not_found)
        end
      end,
      @unlogged
    )
    |> tap(&emit(:class_booking_cancelled, &1))
  end

  ## Staff side

  @doc """
  The roster of one class: a summary (capacity, confirmed, seats left,
  checked in) and its bookings, oldest first (params: `status` `confirmed`
  (default) or `cancelled`, `limit`, `cursor`). Every staff role; a coach
  only for a class they instruct.
  """
  @spec roster(User.t(), term(), term(), map()) :: {:ok, map()} | {:error, error()}
  def roster(%User{} = user, gym_id, occurrence_id, params) when is_map(params) do
    with {:ok, access} <- Access.authorize(user, gym_id, :view_rosters),
         %ClassOccurrence{} = occurrence <-
           fetch_occurrence(access.gym.id, occurrence_id) || {:error, :not_found},
         :ok <- own_class(access, occurrence),
         {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, [:confirmed, :cancelled], :confirmed) do
      {rows, next} =
        from(b in ClassBooking,
          where: b.occurrence_id == ^occurrence.id and b.status == ^status,
          order_by: [asc: b.confirmed_at, asc: b.id],
          limit: ^(limit + 1)
        )
        |> Paging.seek(cursor, :confirmed_at, :asc)
        |> Repo.all(@unlogged)
        |> Paging.page(limit, :confirmed_at)

      {:ok,
       %{
         summary: summary(occurrence),
         entries: roster_views(rows),
         next_cursor: next
       }}
    end
  end

  @doc """
  Books a place for an active member (`attrs`: `gym_member_id`,
  `client_request_id`): owner, managers and front desk.
  `{:ok, {view, :created | :existing}}`.
  """
  @spec book_for(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, error()}
  def book_for(%User{} = user, %Session{} = session, gym_id, occurrence_id, attrs)
      when is_map(attrs) do
    with {:ok, params} <- booking_params(attrs, @staff_booking_fields, :gym_member_id) do
      Schedule.write(
        user,
        session,
        gym_id,
        :book_for_member,
        &book_for_in(&1.gym, user, occurrence_id, params)
      )
    end
    |> tap(&emit(:class_booking_created, &1))
  end

  defp book_for_in(gym, user, occurrence_id, params) do
    with {:ok, member} <- lock_member_of(gym.id, params.gym_member_id),
         {:ok, result} <- place(member, occurrence_id, params, :staff, user) do
      {:ok, {staff_view(result.booking, result.occurrence), result.outcome}}
    end
  end

  @doc """
  Cancels a member's booking as the gym (`staff_cancelled`): owner,
  managers and front desk, until the class starts.
  """
  @spec cancel_for(User.t(), Session.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def cancel_for(%User{} = user, %Session{} = session, gym_id, booking_id) do
    Schedule.write(user, session, gym_id, :book_for_member, fn %{gym: gym} ->
      with %ClassBooking{} = booking <- lock_booking(gym.id, booking_id) || {:error, :not_found},
           {:ok, cancelled} <- cancel(booking, :staff_cancelled, user.id) do
        {:ok, staff_view(cancelled, Repo.get!(ClassOccurrence, cancelled.occurrence_id))}
      end
    end)
    |> tap(&emit(:class_booking_cancelled, &1))
  end

  @doc """
  Records that the member of a confirmed booking came (every staff role),
  on the class's local day. A repeat returns the same check-in.
  `{:ok, {view, :created | :existing}}`.
  """
  @spec check_in(User.t(), Session.t(), term(), term()) ::
          {:ok, {map(), :created | :existing}} | {:error, error()}
  def check_in(%User{} = user, %Session{} = session, gym_id, booking_id) do
    Schedule.write(user, session, gym_id, :record_check_in, fn access ->
      with %ClassBooking{} = booking <-
             lock_booking(access.gym.id, booking_id) || {:error, :not_found} do
        record(access, booking, user)
      end
    end)
    |> tap(&emit(:class_check_in_recorded, &1))
  end

  ## Integration (SF-97 classes, SF-95 memberships, SF-90 checklist)

  @doc false
  # Releases the confirmed bookings of classes being cancelled (inside the
  # cancelling transaction, before the classes' status changes): one audit
  # event per class with how many bookings it released.
  @spec release_occurrences!(Ecto.UUID.t(), [Ecto.UUID.t()], Ecto.UUID.t(), DateTime.t()) :: :ok
  def release_occurrences!(_gym_id, [], _actor_user_id, _now), do: :ok

  def release_occurrences!(gym_id, occurrence_ids, actor_user_id, now) do
    {_count, released} =
      Repo.update_all(
        from(b in ClassBooking,
          where: b.occurrence_id in ^occurrence_ids and b.status == :confirmed,
          select: b.occurrence_id
        ),
        [
          set: [
            status: :cancelled,
            cancel_reason: :occurrence_cancelled,
            cancelled_at: now,
            cancelled_by_user_id: actor_user_id,
            updated_at: now
          ]
        ],
        @unlogged
      )

    released
    |> Enum.frequencies()
    |> Enum.each(fn {occurrence_id, count} ->
      audit!(
        gym_id,
        actor_user_id,
        :class_bookings_released,
        %{class_occurrence_id: occurrence_id, booking_count: count},
        now
      )
    end)
  end

  @doc false
  # Releases an ending membership's bookings of classes still to come that
  # have no check-in (inside the transaction that ends it).
  @spec release_member!(Member.t(), Ecto.UUID.t() | nil, DateTime.t()) :: :ok
  def release_member!(%Member{id: member_id, gym_id: gym_id}, actor_user_id, now) do
    clock = Clock.utc_now()

    {count, _} =
      Repo.update_all(
        from(b in ClassBooking,
          where:
            b.gym_member_id == ^member_id and b.status == :confirmed and
              b.occurrence_id in subquery(
                from(o in ClassOccurrence, where: o.starts_at > ^clock, select: o.id)
              ) and
              b.id not in subquery(
                from(c in ClassCheckIn,
                  where: c.gym_member_id == ^member_id,
                  select: c.booking_id
                )
              )
        ),
        [
          set: [
            status: :cancelled,
            cancel_reason: :membership_ended,
            cancelled_at: now,
            cancelled_by_user_id: actor_user_id,
            updated_at: now
          ]
        ],
        @unlogged
      )

    if count > 0 do
      audit!(
        gym_id,
        actor_user_id,
        :class_bookings_released,
        %{gym_member_id: member_id, booking_count: count},
        now
      )
    end

    :ok
  end

  @doc false
  # The confirmed bookings of each class (classes without any are absent).
  @spec confirmed_counts([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => non_neg_integer()}
  def confirmed_counts([]), do: %{}

  def confirmed_counts(occurrence_ids) do
    Repo.all(
      from(b in ClassBooking,
        where: b.occurrence_id in ^occurrence_ids and b.status == :confirmed,
        group_by: b.occurrence_id,
        select: {b.occurrence_id, count(b.id)}
      ),
      @unlogged
    )
    |> Map.new()
  end

  @doc false
  # Whether the gym has recorded any check-in (the `first_check_in` milestone).
  @spec any_check_in?(Ecto.UUID.t()) :: boolean()
  def any_check_in?(gym_id),
    do: Repo.exists?(from(c in ClassCheckIn, where: c.gym_id == ^gym_id), @unlogged)

  ## Booking

  defp place(member, occurrence_id, params, via, actor) do
    with {:ok, occurrence} <- lock_occurrence(member.gym_id, occurrence_id) do
      case existing(member.gym_id, params.client_request_id) do
        nil -> confirm(member, occurrence, params, via, actor)
        booking -> replay(booking, member, occurrence)
      end
    end
  end

  defp confirm(member, occurrence, params, via, actor) do
    with :ok <- limit(actor),
         :ok <- bookable(occurrence),
         :ok <- not_booked(occurrence.id, member.id),
         :ok <- seat(occurrence) do
      now = DateTime.utc_now()

      %ClassBooking{
        gym_id: member.gym_id,
        occurrence_id: occurrence.id,
        gym_member_id: member.id,
        status: :confirmed,
        booked_via: via,
        booked_by_user_id: actor.id,
        client_request_id: params.client_request_id,
        confirmed_at: now
      }
      |> Changeset.change()
      |> Changeset.unique_constraint(:client_request_id,
        name: :gym_class_bookings_request_index
      )
      |> Changeset.unique_constraint(:occurrence_id, name: :gym_class_bookings_current_index)
      |> Repo.insert(@unlogged)
      |> case do
        {:ok, booking} ->
          audit!(member.gym_id, actor.id, :class_booking_created, booking_ids(booking), now)
          {:ok, %{booking: booking, occurrence: occurrence, outcome: :created}}

        {:error, %Changeset{errors: errors}} ->
          {:error, insert_conflict(errors)}
      end
    end
  end

  # The same key again: the booking it made (whatever its status now), for
  # the same member and class only.
  defp replay(%ClassBooking{} = booking, member, occurrence) do
    if booking.gym_member_id == member.id and booking.occurrence_id == occurrence.id,
      do: {:ok, %{booking: booking, occurrence: occurrence, outcome: :existing}},
      else: {:error, {:conflict, %{client_request_id: "reused"}}}
  end

  defp insert_conflict(errors) do
    if Keyword.has_key?(errors, :client_request_id),
      do: {:conflict, %{client_request_id: "reused"}},
      else: {:conflict, %{class_booking: "already_booked"}}
  end

  defp bookable(%ClassOccurrence{status: :cancelled}),
    do: {:error, {:conflict, %{class_occurrence: "cancelled"}}}

  defp bookable(%ClassOccurrence{starts_at: starts_at}) do
    if DateTime.compare(starts_at, Clock.utc_now()) == :gt,
      do: :ok,
      else: {:error, {:conflict, %{class_occurrence: "started"}}}
  end

  defp not_booked(occurrence_id, member_id) do
    if Repo.exists?(
         from(b in ClassBooking,
           where:
             b.occurrence_id == ^occurrence_id and b.gym_member_id == ^member_id and
               b.status == :confirmed
         ),
         @unlogged
       ),
       do: {:error, {:conflict, %{class_booking: "already_booked"}}},
       else: :ok
  end

  # Counted under the occurrence row lock: no other booking of this class
  # can commit in between.
  defp seat(%ClassOccurrence{id: id, capacity: capacity}) do
    if Map.get(confirmed_counts([id]), id, 0) < capacity,
      do: :ok,
      else: {:error, {:conflict, %{class_occurrence: "full", capacity: capacity}}}
  end

  ## Cancellation

  defp cancel(%ClassBooking{status: :cancelled, cancel_reason: reason} = booking, reason, _actor),
    do: {:ok, booking}

  defp cancel(%ClassBooking{status: :cancelled, cancel_reason: reason}, _reason, _actor),
    do:
      {:error, {:conflict, %{class_booking: "cancelled", cancel_reason: Atom.to_string(reason)}}}

  defp cancel(%ClassBooking{} = booking, reason, actor_id) do
    occurrence = Repo.get!(ClassOccurrence, booking.occurrence_id, @unlogged)

    with :ok <- not_checked_in(booking),
         :ok <- bookable(occurrence) do
      now = DateTime.utc_now()

      cancelled =
        booking
        |> Changeset.change(
          status: :cancelled,
          cancel_reason: reason,
          cancelled_at: now,
          cancelled_by_user_id: actor_id,
          updated_at: now
        )
        |> Repo.update!(@unlogged)

      audit!(booking.gym_id, actor_id, :class_booking_cancelled, booking_ids(cancelled), now)
      {:ok, cancelled}
    end
  end

  defp not_checked_in(%ClassBooking{id: id}) do
    if Repo.exists?(from(c in ClassCheckIn, where: c.booking_id == ^id), @unlogged),
      do: {:error, {:conflict, %{class_booking: "checked_in"}}},
      else: :ok
  end

  ## Check-in

  defp record(access, booking, user) do
    case Repo.one(from(c in ClassCheckIn, where: c.booking_id == ^booking.id), @unlogged) do
      %ClassCheckIn{} = existing -> {:ok, {check_in_view(existing), :existing}}
      nil -> record_new(access, booking, user)
    end
  end

  defp record_new(access, booking, user) do
    occurrence = Repo.get!(ClassOccurrence, booking.occurrence_id, @unlogged)

    with :ok <- checkable(booking, occurrence) do
      now = DateTime.utc_now()

      check_in =
        Repo.insert!(
          %ClassCheckIn{
            gym_id: booking.gym_id,
            occurrence_id: booking.occurrence_id,
            booking_id: booking.id,
            gym_member_id: booking.gym_member_id,
            recorded_by_user_id: user.id,
            recorded_by_staff_membership_id: access.membership.id,
            method: :manual,
            checked_in_at: now,
            inserted_at: now
          },
          @unlogged
        )

      audit!(booking.gym_id, user.id, :class_check_in_recorded, booking_ids(booking), now)
      {:ok, {check_in_view(check_in), :created}}
    end
  end

  defp checkable(%ClassBooking{status: :cancelled}, _occurrence),
    do: {:error, {:conflict, %{class_booking: "cancelled"}}}

  defp checkable(_booking, %ClassOccurrence{status: :cancelled}),
    do: {:error, {:conflict, %{class_occurrence: "cancelled"}}}

  defp checkable(_booking, %ClassOccurrence{starts_at: starts_at, time_zone: zone}) do
    {today, _time} = Scheduling.local(Clock.utc_now(), zone)
    {class_day, _time} = Scheduling.local(starts_at, zone)

    if Date.compare(today, class_day) == :eq,
      do: :ok,
      else: {:error, {:conflict, %{class_occurrence: "not_today"}}}
  end

  ## Locks and lookups

  # The caller's own membership (any status), then the gym (`FOR SHARE`)
  # and the membership (`FOR SHARE`); active only.
  defp lock_own_member(user, member_id) do
    with {:ok, id} <- cast(member_id),
         %Member{gym_id: gym_id} <-
           Repo.one(from(m in Member, where: m.id == ^id and m.user_id == ^user.id), @unlogged),
         %Gym{setup_status: :completed} <- Access.lock_gym_shared!(gym_id),
         %Member{} = member <-
           Repo.one(
             from(m in Member, where: m.id == ^id and m.user_id == ^user.id, lock: "FOR SHARE"),
             @unlogged
           ) do
      active(member)
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_member_of(gym_id, member_id) do
    with {:ok, id} <- cast(member_id),
         %Member{} = member <-
           Repo.one(
             from(m in Member, where: m.id == ^id and m.gym_id == ^gym_id, lock: "FOR SHARE"),
             @unlogged
           ) do
      active(member)
    else
      _ ->
        {:error, Schedule.field_error(:gym_member_id, "is not a member of this gym", :inclusion)}
    end
  end

  defp own_active(user, member_id) do
    with {:ok, id} <- cast(member_id),
         %Member{} = member <-
           Repo.one(from(m in Member, where: m.id == ^id and m.user_id == ^user.id), @unlogged) do
      active(member)
    else
      _ -> {:error, :not_found}
    end
  end

  defp active(%Member{status: :active} = member), do: {:ok, member}

  defp active(%Member{status: status}),
    do: {:error, {:conflict, %{gym_member: Atom.to_string(status)}}}

  defp lock_occurrence(gym_id, occurrence_id) do
    with {:ok, id} <- cast(occurrence_id),
         %ClassOccurrence{} = occurrence <-
           Repo.one(
             from(o in ClassOccurrence,
               where: o.id == ^id and o.gym_id == ^gym_id,
               lock: "FOR UPDATE"
             ),
             @unlogged
           ) do
      {:ok, occurrence}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_occurrence(gym_id, occurrence_id) do
    case cast(occurrence_id) do
      {:ok, id} ->
        Repo.one(
          from(o in ClassOccurrence, where: o.id == ^id and o.gym_id == ^gym_id),
          @unlogged
        )

      :error ->
        nil
    end
  end

  defp own_booking(user, booking_id) do
    case cast(booking_id) do
      {:ok, id} ->
        Repo.one(
          from(b in ClassBooking,
            join: m in Member,
            on: m.id == b.gym_member_id,
            where: b.id == ^id and m.user_id == ^user.id
          ),
          @unlogged
        )

      :error ->
        nil
    end
  end

  defp lock_booking(gym_id, booking_id) do
    case cast(booking_id) do
      {:ok, id} ->
        Repo.one(
          from(b in ClassBooking, where: b.id == ^id and b.gym_id == ^gym_id, lock: "FOR UPDATE"),
          @unlogged
        )

      :error ->
        nil
    end
  end

  defp existing(gym_id, key) do
    Repo.one(
      from(b in ClassBooking, where: b.gym_id == ^gym_id and b.client_request_id == ^key),
      @unlogged
    )
  end

  defp own_class(%{scope: :all}, _occurrence), do: :ok

  defp own_class(%{scope: :own_occurrences, membership: membership}, %ClassOccurrence{
         instructor_staff_membership_id: instructor
       })
       when instructor == membership.id,
       do: :ok

  defp own_class(_access, _occurrence), do: {:error, :forbidden}

  defp cast(id) do
    case Access.cast_id(id) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  ## Params

  defp booking_params(attrs, allowed, target) do
    types = %{target => Ecto.UUID, client_request_id: Ecto.UUID}

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required(Map.keys(types))
    |> Schedule.reject_unknown(attrs, allowed)
    |> Schedule.apply()
  end

  ## Views

  defp summary(%ClassOccurrence{id: id, capacity: capacity}) do
    confirmed = Map.get(confirmed_counts([id]), id, 0)

    checked_in =
      Repo.aggregate(
        from(c in ClassCheckIn,
          join: b in ClassBooking,
          on: b.id == c.booking_id,
          where: c.occurrence_id == ^id and b.status == :confirmed
        ),
        :count,
        @unlogged
      )

    %{
      capacity: capacity,
      confirmed_count: confirmed,
      remaining_capacity: max(capacity - confirmed, 0),
      checked_in_count: checked_in
    }
  end

  defp member_classes([], _member), do: []

  defp member_classes(rows, member) do
    ids = Enum.map(rows, & &1.id)
    counts = confirmed_counts(ids)
    mine = own_bookings_of(member.id, ids)

    rows
    |> Timetable.views()
    |> Enum.map(fn view ->
      seats = view.capacity - Map.get(counts, view.occurrence_id, 0)

      %{
        occurrence_id: view.occurrence_id,
        title: view.title,
        status: view.status,
        starts_at: view.starts_at,
        ends_at: view.ends_at,
        time_zone: view.time_zone,
        local_starts_at: view.local_starts_at,
        local_ends_at: view.local_ends_at,
        utc_offset_minutes: view.utc_offset_minutes,
        duration_minutes: view.duration_minutes,
        venue: %{name: view.venue.name},
        instructor: view.instructor && %{name: view.instructor.name},
        capacity: view.capacity,
        remaining_capacity: if(view.status == :scheduled, do: max(seats, 0), else: 0),
        booking: Map.get(mine, view.occurrence_id)
      }
    end)
  end

  # The member's booking of each class: the confirmed one, else the latest.
  defp own_bookings_of(member_id, occurrence_ids) do
    rows =
      Repo.all(
        from(b in ClassBooking,
          where: b.gym_member_id == ^member_id and b.occurrence_id in ^occurrence_ids,
          order_by: [asc: b.inserted_at]
        ),
        @unlogged
      )

    checked = checked_in_at(Enum.map(rows, & &1.id))

    rows
    |> Enum.group_by(& &1.occurrence_id)
    |> Map.new(fn {occurrence_id, bookings} ->
      booking =
        Enum.find(bookings, &(&1.status == :confirmed)) || List.last(bookings)

      {occurrence_id,
       %{
         booking_id: booking.id,
         status: booking.status,
         checked_in_at: Map.get(checked, booking.id)
       }}
    end)
  end

  defp own_views([]), do: []

  defp own_views(bookings) do
    occurrences =
      Repo.all(
        from(o in ClassOccurrence, where: o.id in ^Enum.map(bookings, & &1.occurrence_id)),
        @unlogged
      )

    views = occurrences |> Timetable.views() |> Map.new(&{&1.occurrence_id, &1})
    gyms = gym_names(Enum.map(occurrences, & &1.gym_id))
    checked = checked_in_at(Enum.map(bookings, & &1.id))

    Enum.map(bookings, fn booking ->
      own_projection(booking, Map.fetch!(views, booking.occurrence_id), gyms, checked)
    end)
  end

  defp own_view(booking, %ClassOccurrence{} = occurrence) do
    [view] = own_views([booking])
    seats = summary(occurrence)
    Map.put(view, :availability, Map.delete(seats, :checked_in_count))
  end

  defp own_projection(booking, class, gyms, checked) do
    %{
      booking_id: booking.id,
      gym_member_id: booking.gym_member_id,
      status: booking.status,
      booked_via: booking.booked_via,
      confirmed_at: booking.confirmed_at,
      cancelled_at: booking.cancelled_at,
      cancel_reason: booking.cancel_reason,
      checked_in_at: Map.get(checked, booking.id),
      class: %{
        occurrence_id: class.occurrence_id,
        gym: %{gym_id: class.gym_id, name: Map.get(gyms, class.gym_id)},
        title: class.title,
        status: class.status,
        starts_at: class.starts_at,
        ends_at: class.ends_at,
        time_zone: class.time_zone,
        local_starts_at: class.local_starts_at,
        local_ends_at: class.local_ends_at,
        utc_offset_minutes: class.utc_offset_minutes,
        venue: %{name: class.venue.name},
        instructor: class.instructor && %{name: class.instructor.name}
      }
    }
  end

  defp roster_views([]), do: []

  defp roster_views(bookings) do
    members =
      Repo.all(
        from(m in Member,
          where: m.id in ^Enum.map(bookings, & &1.gym_member_id),
          select: {m.id, m.user_id}
        ),
        @unlogged
      )
      |> Map.new()

    names = members |> Map.values() |> Enum.reject(&is_nil/1) |> Accounts.short_names()
    checked = checked_in_at(Enum.map(bookings, & &1.id))

    Enum.map(bookings, fn booking ->
      user_id = Map.get(members, booking.gym_member_id)
      roster_projection(booking, get_in(names, [user_id, :short_name]), checked)
    end)
  end

  defp roster_projection(booking, name, checked) do
    %{
      booking_id: booking.id,
      gym_member_id: booking.gym_member_id,
      name: name,
      status: booking.status,
      booked_via: booking.booked_via,
      confirmed_at: booking.confirmed_at,
      cancelled_at: booking.cancelled_at,
      cancel_reason: booking.cancel_reason,
      checked_in_at: Map.get(checked, booking.id)
    }
  end

  defp staff_view(booking, %ClassOccurrence{} = occurrence) do
    [view] = roster_views([booking])
    Map.merge(view, %{occurrence_id: booking.occurrence_id, summary: summary(occurrence)})
  end

  defp check_in_view(%ClassCheckIn{} = check_in) do
    %{
      check_in_id: check_in.id,
      booking_id: check_in.booking_id,
      occurrence_id: check_in.occurrence_id,
      gym_member_id: check_in.gym_member_id,
      method: check_in.method,
      checked_in_at: check_in.checked_in_at
    }
  end

  defp checked_in_at([]), do: %{}

  defp checked_in_at(booking_ids) do
    Repo.all(
      from(c in ClassCheckIn,
        where: c.booking_id in ^booking_ids,
        select: {c.booking_id, c.checked_in_at}
      ),
      @unlogged
    )
    |> Map.new()
  end

  defp gym_names(gym_ids) do
    Repo.all(
      from(g in Gym, where: g.id in ^Enum.uniq(gym_ids), select: {g.id, g.name}),
      @unlogged
    )
    |> Map.new()
  end

  ## Audit, limits, telemetry

  defp booking_ids(%ClassBooking{} = booking),
    do: %{
      class_booking_id: booking.id,
      class_occurrence_id: booking.occurrence_id,
      gym_member_id: booking.gym_member_id
    }

  defp audit!(gym_id, actor_id, event, ids, now),
    do:
      Audit.record!(
        Map.merge(%{gym_id: gym_id, actor_user_id: actor_id, event_type: event}, ids),
        now
      )

  # Bookings and cancellations: 60 per 10 minutes per user (members and staff
  # alike; a replayed key is answered before it counts).
  defp limit(%User{id: user_id}),
    do:
      RateLimit.hit([
        {"gym_booking_user", MemberSecrets.rate_limit_key("user", user_id), 60, 600}
      ])

  # Outcomes only: never a name, an id or a token.
  defp emit(event, result) do
    outcome =
      case result do
        {:ok, {_view, outcome}} when outcome in [:created, :existing] -> outcome
        {:ok, _} -> :ok
        {:error, %Changeset{}} -> :validation_error
        {:error, {:conflict, details}} -> conflict_outcome(details)
        {:error, {:rate_limited, _}} -> :rate_limited
        {:error, reason} when is_atom(reason) -> reason
      end

    :telemetry.execute([:simple_fit, :gyms, :booking, event], %{count: 1}, %{outcome: outcome})
  end

  # A bounded vocabulary (the conflict's code), never free text.
  defp conflict_outcome(%{class_occurrence: "full"}), do: :full
  defp conflict_outcome(%{class_booking: "already_booked"}), do: :already_booked
  defp conflict_outcome(_details), do: :conflict
end
