defmodule SimpleFit.Gyms.Timetable do
  @moduledoc """
  The gym timetable (SF-97): one-time classes, weekly series and their
  occurrences. Internal to `SimpleFit.Gyms`; see `ClassOccurrence` and
  `ClassSeries` for the model and `SimpleFit.Scheduling` for the time rules.

  ## Who

  Every active staff member reads the timetable (`view_workspace`). Owners
  and managers (`manage_timetable`) create, reschedule and regenerate
  classes and series and cancel series. Cancelling one class is
  `cancel_occurrence`: owners and managers any class, a coach only a class
  they instruct (`own_occurrences`). Front desk reads only.

  ## Time

  A one-time class is given as an RFC 3339 instant with its offset, which
  must be the venue zone's offset at that instant: a spring-gap time cannot
  be expressed and a repeated autumn hour is chosen by its offset. A series
  is a wall-clock rule in its venue's zone, resolved date by date; a date on
  which the local start time does not exist or exists twice is skipped and
  reported (`skipped_dates`, reason `nonexistent_local_time` or
  `ambiguous_local_time`), never shifted or guessed: such a class is
  scheduled as a one-time class with an explicit offset. A class lasts
  exactly its duration in elapsed time. Classes start in the future and at
  most a year ahead; nothing that has started is changed or cancelled.

  ## Series

  A series spans at most a year and is materialized completely when it is
  created or changed, so every class it schedules exists and has been
  checked against its venue and instructor (no projected, unchecked
  classes). Each date has one row (`series_local_date`), so regenerating
  never duplicates, and a cancelled class never comes back.

  Changing a series (weekdays, start time, duration, capacity, venue,
  instructor, last date) rewrites only its classes still to come that were
  not changed or cancelled on their own: a matching date is updated, a date
  the rule no longer has is cancelled (`series_changed`) and may return if a
  later rule has it again, a new date is created. Classes that started,
  classes changed on their own (`rescheduled_at`) and classes cancelled by a
  person stay exactly as they are. Cancelling a series cancels all its
  classes still to come (`series_cancelled`); it is final.

  ## Conflicts

  A venue holds one scheduled class at a time, and a person instructs one
  scheduled class at a time across every gym, on half-open intervals
  (adjacent classes are fine). PostgreSQL enforces both (exclusion
  constraints); a conflict is `409 schedule: venue_unavailable` (with the
  dates of this gym's classes in the way) or `schedule:
  instructor_unavailable` (no details: the other class may be another
  gym's). Booking capacity is only the limit a future Booking domain
  enforces (`active_bookings <= capacity`); nothing is reserved here.

  ## Instructors

  An instructor is an active owner, manager or coach of the gym (never
  inferred from a CoachProfile). When their staff membership ends or they
  become front desk, `release_instructor!/4` takes them off every class
  still to come (marked as needing an instructor), their series and their
  template defaults, in the same transaction; past classes keep them.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.{Clock, Repo, Scheduling}

  alias SimpleFit.Gyms.{
    Access,
    Audit,
    Bookings,
    ClassOccurrence,
    ClassSeries,
    ClassTemplate,
    ClassTemplates,
    Paging,
    Schedule,
    Venue,
    Venues
  }

  @unlogged [log: false]
  @max_days 31
  @deferred "SET CONSTRAINTS gym_class_occurrences_venue_overlap, gym_class_occurrences_instructor_overlap"

  ## Reads

  @doc """
  The gym's classes in a window (params: `from`, `to` (RFC 3339 instants,
  at most #{@max_days} days apart), optional `status`, `venue_id`,
  `instructor_staff_membership_id`, `template_id`, `series_id`, `limit`,
  `cursor`), by start time.
  """
  @spec list_occurrences(User.t(), term(), map()) :: {:ok, map()} | {:error, Schedule.error()}
  def list_occurrences(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym}} <- Schedule.read(user, gym_id),
         {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, [:scheduled, :cancelled]),
         {:ok, filters} <- list_filters(params) do
      query =
        from(o in ClassOccurrence,
          where:
            o.gym_id == ^gym.id and o.starts_at >= ^filters.from and o.starts_at < ^filters.to,
          order_by: [asc: o.starts_at, asc: o.id],
          limit: ^(limit + 1)
        )
        |> filter(:status, status)
        |> filter(:venue_id, filters[:venue_id])
        |> filter(:instructor_staff_membership_id, filters[:instructor_staff_membership_id])
        |> filter(:template_id, filters[:template_id])
        |> filter(:series_id, filters[:series_id])
        |> Paging.seek(cursor, :starts_at, :asc)

      {rows, next} = query |> Repo.all(@unlogged) |> Paging.page(limit, :starts_at)
      {:ok, %{entries: occurrence_views(rows), next_cursor: next}}
    end
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: from(o in query, where: field(o, ^field) == ^value)

  @doc "One class of the gym."
  @spec get_occurrence(User.t(), term(), term()) :: {:ok, map()} | {:error, Schedule.error()}
  def get_occurrence(%User{} = user, gym_id, occurrence_id) do
    with {:ok, %{gym: gym}} <- Schedule.read(user, gym_id),
         %ClassOccurrence{} = occurrence <- fetch_occurrence(gym.id, occurrence_id, false) do
      {:ok, occurrence_view(occurrence)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The gym's series, newest first (params: `status` `active` (default) or `cancelled`, `limit`)."
  @spec list_series(User.t(), term(), map()) :: {:ok, map()} | {:error, Schedule.error()}
  def list_series(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym}} <- Schedule.read(user, gym_id),
         {:ok, %{limit: limit, status: status}} <-
           Paging.params(Map.delete(params, "cursor"), [:active, :cancelled], :active) do
      series =
        Repo.all(
          from(s in ClassSeries,
            where: s.gym_id == ^gym.id and s.status == ^status,
            order_by: [desc: s.inserted_at, desc: s.id],
            limit: ^limit
          ),
          @unlogged
        )

      {:ok, %{entries: Enum.map(series, &series_view(&1, false))}}
    end
  end

  @doc "One series of the gym, with its skipped dates and class counts."
  @spec get_series(User.t(), term(), term()) :: {:ok, map()} | {:error, Schedule.error()}
  def get_series(%User{} = user, gym_id, series_id) do
    with {:ok, %{gym: gym}} <- Schedule.read(user, gym_id),
         %ClassSeries{} = series <- fetch_series(gym.id, series_id, false) do
      {:ok, series_view(series, true)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  ## One-time classes

  @doc """
  Schedules a one-time class (`attrs`: `client_request_id`, `template_id`,
  `starts_at`; optional `venue_id`, `instructor_staff_membership_id`,
  `duration_minutes`, `capacity`, each defaulting to the template's). The
  same `client_request_id` again returns the class it created.
  """
  @spec create_occurrence(User.t(), Session.t(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, Schedule.error()}
  def create_occurrence(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    Schedule.write(
      user,
      session,
      gym_id,
      :manage_timetable,
      &create_occurrence_in(&1.gym, user, attrs)
    )
    |> tap(&Schedule.emit(:class_occurrence_created, &1))
  end

  defp create_occurrence_in(gym, user, attrs) do
    with {:ok, params} <- occurrence_params(attrs) do
      case Repo.get_by(
             ClassOccurrence,
             [gym_id: gym.id, client_request_id: params.client_request_id],
             @unlogged
           ) do
        %ClassOccurrence{} = existing -> {:ok, {occurrence_view(existing), :existing}}
        nil -> insert_one_time(gym.id, user, params, attrs)
      end
    end
  end

  defp insert_one_time(gym_id, user, params, attrs) do
    with {:ok, template} <- template(gym_id, params.template_id),
         {:ok, venue} <- venue(gym_id, params[:venue_id] || template.default_venue_id),
         {:ok, instructor} <-
           Schedule.instructor(
             gym_id,
             pick(
               attrs,
               params,
               :instructor_staff_membership_id,
               template.default_instructor_staff_membership_id
             ),
             :instructor_staff_membership_id
           ),
         capacity = params[:capacity] || template.default_capacity,
         duration = params[:duration_minutes] || template.default_duration_minutes,
         :ok <- fits(venue, capacity),
         {:ok, starts_at} <- instant(attrs["starts_at"], params.starts_at, venue.time_zone) do
      now = DateTime.utc_now()

      %ClassOccurrence{
        gym_id: gym_id,
        template_id: template.id,
        venue_id: venue.id,
        instructor_staff_membership_id: instructor && instructor.id,
        title: template.title,
        time_zone: venue.time_zone,
        starts_at: starts_at,
        ends_at: DateTime.add(starts_at, duration * 60, :second),
        duration_minutes: duration,
        capacity: capacity,
        client_request_id: params.client_request_id,
        created_by_user_id: user.id
      }
      |> Changeset.change()
      |> constrained()
      |> Repo.insert(@unlogged)
      |> case do
        {:ok, occurrence} ->
          audit!(
            gym_id,
            user.id,
            :class_occurrence_created,
            %{class_occurrence_id: occurrence.id},
            now
          )

          {:ok, {occurrence_view(occurrence), :created}}

        {:error, changeset} ->
          {:error, constraint_error(changeset)}
      end
    end
  end

  @doc """
  Changes one class still to come (`attrs`: `expected_revision` and any of
  `starts_at`, `duration_minutes`, `venue_id` (a venue in the same zone),
  `instructor_staff_membership_id` (`null` removes the instructor),
  `capacity`). Every rule and conflict is checked again. A series class
  changed this way becomes an exception: later series changes leave it.
  """
  @spec update_occurrence(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, Schedule.error()}
  def update_occurrence(%User{} = user, %Session{} = session, gym_id, occurrence_id, attrs)
      when is_map(attrs) do
    Schedule.write(user, session, gym_id, :manage_timetable, fn %{gym: gym} ->
      with %ClassOccurrence{} = occurrence <-
             fetch_occurrence(gym.id, occurrence_id, true) || {:error, :not_found},
           :ok <- changeable(occurrence),
           :ok <- Schedule.revision(attrs, occurrence.revision),
           {:ok, params} <- reschedule_params(attrs),
           {:ok, changes} <- reschedule_changes(gym.id, occurrence, params, attrs) do
        apply_reschedule(gym.id, user, occurrence, changes)
      end
    end)
    |> tap(&Schedule.emit(:class_occurrence_rescheduled, &1))
  end

  defp reschedule_changes(gym_id, occurrence, params, attrs) do
    with {:ok, venue} <- venue(gym_id, params[:venue_id] || occurrence.venue_id),
         :ok <- same_zone(venue, occurrence),
         {:ok, instructor} <-
           Schedule.instructor(
             gym_id,
             pick(
               attrs,
               params,
               :instructor_staff_membership_id,
               occurrence.instructor_staff_membership_id
             ),
             :instructor_staff_membership_id
           ),
         capacity = params[:capacity] || occurrence.capacity,
         duration = params[:duration_minutes] || occurrence.duration_minutes,
         :ok <- fits(venue, capacity),
         :ok <- holds_bookings(occurrence, capacity),
         {:ok, starts_at} <-
           if(Map.has_key?(attrs, "starts_at"),
             do: instant(attrs["starts_at"], params[:starts_at], occurrence.time_zone),
             else: {:ok, occurrence.starts_at}
           ) do
      {:ok,
       %{
         starts_at: starts_at,
         ends_at: DateTime.add(starts_at, duration * 60, :second),
         duration_minutes: duration,
         venue_id: venue.id,
         instructor_staff_membership_id: instructor && instructor.id,
         capacity: capacity
       }}
    end
  end

  defp apply_reschedule(gym_id, user, occurrence, changes) do
    changed = Map.reject(changes, fn {key, value} -> Map.get(occurrence, key) == value end)

    if changed == %{} do
      {:ok, occurrence_view(occurrence)}
    else
      now = DateTime.utc_now()

      extra =
        %{revision: occurrence.revision + 1, updated_at: now}
        |> then(&if(occurrence.series_id, do: Map.put(&1, :rescheduled_at, now), else: &1))
        |> then(
          &if(Map.has_key?(changed, :instructor_staff_membership_id),
            do: Map.put(&1, :instructor_released_at, nil),
            else: &1
          )
        )

      occurrence
      |> Changeset.change(Map.merge(changed, extra))
      |> constrained()
      |> Repo.update(@unlogged)
      |> case do
        {:ok, updated} ->
          audit_changes!(gym_id, user.id, updated.id, changed, now)
          {:ok, occurrence_view(updated)}

        {:error, changeset} ->
          {:error, constraint_error(changeset)}
      end
    end
  end

  # One event per kind of change: when, how long or where; who; how many.
  defp audit_changes!(gym_id, actor_id, occurrence_id, changed, now) do
    for {event, keys} <- [
          class_occurrence_rescheduled: [:starts_at, :duration_minutes, :venue_id],
          class_instructor_changed: [:instructor_staff_membership_id],
          class_capacity_changed: [:capacity]
        ],
        Enum.any?(keys, &Map.has_key?(changed, &1)) do
      audit!(gym_id, actor_id, event, %{class_occurrence_id: occurrence_id}, now)
    end

    :ok
  end

  @doc """
  Cancels one class still to come (`attrs`: `expected_revision`). Owners
  and managers any class; a coach only a class they instruct. It stays as a
  cancelled record, frees its venue and instructor, and never returns.
  Cancelling it again returns it unchanged.
  """
  @spec cancel_occurrence(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, Schedule.error()}
  def cancel_occurrence(%User{} = user, %Session{} = session, gym_id, occurrence_id, attrs)
      when is_map(attrs) do
    Schedule.write(
      user,
      session,
      gym_id,
      :cancel_occurrence,
      &cancel_occurrence_in(&1, user, fetch_occurrence(&1.gym.id, occurrence_id, true), attrs)
    )
    |> tap(&Schedule.emit(:class_occurrence_cancelled, &1))
  end

  defp cancel_occurrence_in(_access, _user, nil, _attrs), do: {:error, :not_found}

  defp cancel_occurrence_in(
         _access,
         _user,
         %ClassOccurrence{status: :cancelled, cancel_reason: :cancelled} = occurrence,
         _attrs
       ),
       do: {:ok, occurrence_view(occurrence)}

  defp cancel_occurrence_in(access, user, %ClassOccurrence{} = occurrence, attrs) do
    with :ok <- own(access, occurrence),
         :ok <- changeable(occurrence),
         :ok <- Schedule.revision(attrs, occurrence.revision) do
      now = DateTime.utc_now()
      # SF-99: its confirmed bookings are released first (same transaction).
      Bookings.release_occurrences!(access.gym.id, [occurrence.id], user.id, now)

      cancelled =
        occurrence
        |> Changeset.change(
          status: :cancelled,
          cancelled_at: now,
          cancel_reason: :cancelled,
          cancelled_by_user_id: user.id,
          revision: occurrence.revision + 1,
          updated_at: now
        )
        |> Repo.update!(@unlogged)

      audit!(
        access.gym.id,
        user.id,
        :class_occurrence_cancelled,
        %{class_occurrence_id: cancelled.id},
        now
      )

      {:ok, occurrence_view(cancelled)}
    end
  end

  defp own(%{scope: :all}, _occurrence), do: :ok

  defp own(%{scope: :own_occurrences, membership: membership}, %ClassOccurrence{
         instructor_staff_membership_id: instructor
       })
       when instructor == membership.id,
       do: :ok

  defp own(_access, _occurrence), do: {:error, :forbidden}

  defp changeable(%ClassOccurrence{status: :cancelled}),
    do: {:error, {:conflict, %{class_occurrence: "cancelled"}}}

  defp changeable(%ClassOccurrence{starts_at: starts_at}) do
    if DateTime.compare(starts_at, Clock.utc_now()) == :gt,
      do: :ok,
      else: {:error, {:conflict, %{class_occurrence: "started"}}}
  end

  ## Series

  @doc """
  Creates a weekly series and schedules all its classes (`attrs`:
  `client_request_id`, `template_id`, `weekdays` (ISO, 1 = Monday),
  `local_start_time` (`HH:MM`), `starts_on`, `ends_on` (at most a year
  later); optional `venue_id`, `instructor_staff_membership_id`,
  `duration_minutes`, `capacity`, each defaulting to the template's). The
  same `client_request_id` again returns the series it created.
  """
  @spec create_series(User.t(), Session.t(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, Schedule.error()}
  def create_series(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    Schedule.write(
      user,
      session,
      gym_id,
      :manage_timetable,
      &create_series_in(&1.gym, user, attrs)
    )
    |> tap(&Schedule.emit(:class_series_created, &1))
  end

  defp create_series_in(gym, user, attrs) do
    with {:ok, params} <- series_params(attrs, nil) do
      case Repo.get_by(
             ClassSeries,
             [gym_id: gym.id, client_request_id: params.client_request_id],
             @unlogged
           ) do
        %ClassSeries{} = existing -> {:ok, {series_view(existing, true), :existing}}
        nil -> insert_series(gym.id, user, params, attrs)
      end
    end
  end

  defp insert_series(gym_id, user, params, attrs) do
    with {:ok, template} <- template(gym_id, params.template_id),
         {:ok, venue} <- venue(gym_id, params[:venue_id] || template.default_venue_id),
         {:ok, instructor} <-
           Schedule.instructor(
             gym_id,
             pick(
               attrs,
               params,
               :instructor_staff_membership_id,
               template.default_instructor_staff_membership_id
             ),
             :instructor_staff_membership_id
           ),
         capacity = params[:capacity] || template.default_capacity,
         :ok <- fits(venue, capacity),
         series = %ClassSeries{
           gym_id: gym_id,
           template_id: template.id,
           venue_id: venue.id,
           instructor_staff_membership_id: instructor && instructor.id,
           time_zone: venue.time_zone,
           weekdays: params.weekdays,
           local_start_time: params.local_start_time,
           duration_minutes: params[:duration_minutes] || template.default_duration_minutes,
           capacity: capacity,
           starts_on: params.starts_on,
           ends_on: params.ends_on,
           client_request_id: params.client_request_id,
           created_by_user_id: user.id
         },
         :ok <- window(series),
         {wanted, _skipped} = expand(series),
         :ok <- some(wanted),
         :ok <- venue_free(series, wanted, []),
         series = Repo.insert!(series, @unlogged),
         :ok <- deferred(fn -> insert_all!(series, template, wanted, user.id) end) do
      audit!(
        gym_id,
        user.id,
        :class_series_created,
        %{class_series_id: series.id, occurrence_count: length(wanted)},
        DateTime.utc_now()
      )

      {:ok, {series_view(series, true), :created}}
    end
  end

  defp insert_all!(series, template, dates, actor_id) do
    Enum.each(dates, fn {date, at} ->
      Repo.insert!(new_occurrence(series, template, date, at, actor_id), @unlogged)
    end)
  end

  @doc """
  Changes a series (`attrs`: `expected_revision` and any of `weekdays`,
  `local_start_time`, `duration_minutes`, `capacity`, `venue_id` (same zone),
  `instructor_staff_membership_id` (`null` removes), `ends_on`) and rewrites
  its classes still to come by the policy in the moduledoc. The whole change
  is refused if any rewritten class would conflict.
  """
  @spec update_series(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, Schedule.error()}
  def update_series(%User{} = user, %Session{} = session, gym_id, series_id, attrs)
      when is_map(attrs) do
    Schedule.write(user, session, gym_id, :manage_timetable, fn %{gym: gym} ->
      with %ClassSeries{} = series <-
             fetch_series(gym.id, series_id, true) || {:error, :not_found},
           :ok <- series_active(series),
           :ok <- Schedule.revision(attrs, series.revision),
           {:ok, params} <- series_params(attrs, series),
           {:ok, venue} <- venue(gym.id, params[:venue_id] || series.venue_id),
           :ok <- same_zone(venue, series),
           {:ok, instructor} <-
             Schedule.instructor(
               gym.id,
               pick(
                 attrs,
                 params,
                 :instructor_staff_membership_id,
                 series.instructor_staff_membership_id
               ),
               :instructor_staff_membership_id
             ),
           next = %{
             series
             | venue_id: venue.id,
               instructor_staff_membership_id: instructor && instructor.id,
               weekdays: params[:weekdays] || series.weekdays,
               local_start_time: params[:local_start_time] || series.local_start_time,
               duration_minutes: params[:duration_minutes] || series.duration_minutes,
               capacity: params[:capacity] || series.capacity,
               ends_on: params[:ends_on] || series.ends_on
           },
           :ok <- fits(venue, next.capacity),
           :ok <- window(next, :update),
           {:ok, touched} <- rematerialize(next, user.id) do
        now = DateTime.utc_now()

        updated =
          series
          |> Changeset.change(
            venue_id: next.venue_id,
            instructor_staff_membership_id: next.instructor_staff_membership_id,
            weekdays: next.weekdays,
            local_start_time: next.local_start_time,
            duration_minutes: next.duration_minutes,
            capacity: next.capacity,
            ends_on: next.ends_on,
            revision: series.revision + 1,
            updated_at: now
          )
          |> Repo.update!(@unlogged)

        audit!(
          gym.id,
          user.id,
          :class_series_updated,
          %{class_series_id: updated.id, occurrence_count: touched},
          now
        )

        {:ok, series_view(updated, true)}
      end
    end)
    |> tap(&Schedule.emit(:class_series_updated, &1))
  end

  @doc """
  Schedules any date of an active series' rule that has no class yet
  (normally none: a series is materialized when written). Idempotent: it
  never duplicates a date, and never brings back a cancelled class.
  `{:ok, {view, created_count}}`.
  """
  @spec generate_series(User.t(), Session.t(), term(), term()) ::
          {:ok, {map(), non_neg_integer()}} | {:error, Schedule.error()}
  def generate_series(%User{} = user, %Session{} = session, gym_id, series_id) do
    Schedule.write(
      user,
      session,
      gym_id,
      :manage_timetable,
      &generate_in(&1.gym, user, series_id)
    )
    |> tap(&Schedule.emit(:class_series_generated, &1))
  end

  defp generate_in(gym, user, series_id) do
    with %ClassSeries{} = series <- fetch_series(gym.id, series_id, true) || {:error, :not_found},
         :ok <- series_active(series),
         template = Repo.get!(ClassTemplate, series.template_id, @unlogged),
         {wanted, _skipped} = expand(series),
         existing = series_dates(series.id),
         missing = Enum.reject(wanted, fn {date, _at} -> MapSet.member?(existing, date) end),
         :ok <- venue_free(series, missing, []),
         :ok <- deferred(fn -> insert_all!(series, template, missing, user.id) end) do
      if missing != [] do
        audit!(
          gym.id,
          user.id,
          :class_series_updated,
          %{class_series_id: series.id, occurrence_count: length(missing)},
          DateTime.utc_now()
        )
      end

      {:ok, {series_view(series, true), length(missing)}}
    end
  end

  # Every date of the series that has a row (any status).
  defp series_dates(series_id) do
    Repo.all(
      from(o in ClassOccurrence, where: o.series_id == ^series_id, select: o.series_local_date),
      @unlogged
    )
    |> MapSet.new()
  end

  @doc """
  Cancels a series (`attrs`: `expected_revision`) and all its classes still
  to come, including ones changed on their own (`series_cancelled`). Past
  classes stay. Final; cancelling it again returns it unchanged.
  """
  @spec cancel_series(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, Schedule.error()}
  def cancel_series(%User{} = user, %Session{} = session, gym_id, series_id, attrs)
      when is_map(attrs) do
    Schedule.write(
      user,
      session,
      gym_id,
      :manage_timetable,
      &cancel_series_in(&1.gym, user, fetch_series(&1.gym.id, series_id, true), attrs)
    )
    |> tap(&Schedule.emit(:class_series_cancelled, &1))
  end

  defp cancel_series_in(_gym, _user, nil, _attrs), do: {:error, :not_found}

  defp cancel_series_in(_gym, _user, %ClassSeries{status: :cancelled} = series, _attrs),
    do: {:ok, series_view(series, true)}

  defp cancel_series_in(gym, user, %ClassSeries{} = series, attrs) do
    with :ok <- Schedule.revision(attrs, series.revision) do
      now = DateTime.utc_now()
      clock = Clock.utc_now()

      # SF-99: the confirmed bookings of the classes it cancels are released
      # first (same transaction; the classes are locked).
      ids =
        Repo.all(
          from(o in ClassOccurrence,
            where: o.series_id == ^series.id and o.status == :scheduled and o.starts_at > ^clock,
            select: o.id,
            lock: "FOR UPDATE"
          ),
          @unlogged
        )

      Bookings.release_occurrences!(gym.id, ids, user.id, now)

      {count, _} =
        Repo.update_all(
          from(o in ClassOccurrence,
            where: o.id in ^ids,
            update: [
              set: [
                status: :cancelled,
                cancelled_at: ^now,
                cancel_reason: :series_cancelled,
                cancelled_by_user_id: ^user.id,
                updated_at: ^now
              ],
              inc: [revision: 1]
            ]
          ),
          [],
          @unlogged
        )

      cancelled =
        series
        |> Changeset.change(
          status: :cancelled,
          cancelled_at: now,
          revision: series.revision + 1,
          updated_at: now
        )
        |> Repo.update!(@unlogged)

      audit!(
        gym.id,
        user.id,
        :class_series_cancelled,
        %{class_series_id: series.id, occurrence_count: count},
        now
      )

      {:ok, series_view(cancelled, true)}
    end
  end

  # The series' classes still to come that follow the rule (not exceptions,
  # not cancelled by a person), rewritten to `next`: kept dates updated, lost
  # dates cancelled (`series_changed`), new or returning dates scheduled.
  defp rematerialize(%ClassSeries{} = next, actor_id) do
    clock = Clock.utc_now()
    template = Repo.get!(ClassTemplate, next.template_id, @unlogged)
    {wanted, _skipped} = expand(next)
    wanted_by_date = Map.new(wanted)

    rows =
      Repo.all(
        from(o in ClassOccurrence,
          where:
            o.series_id == ^next.id and is_nil(o.rescheduled_at) and o.starts_at > ^clock and
              (o.status == :scheduled or o.cancel_reason == :series_changed),
          lock: "FOR UPDATE"
        ),
        @unlogged
      )

    by_date = Map.new(rows, &{&1.series_local_date, &1})

    # Dates of this series that are not rewritten (exceptions, cancelled by
    # a person, started) are never created again.
    kept = series_dates(next.id)
    new = Enum.reject(wanted, fn {date, _at} -> MapSet.member?(kept, date) end)
    followed = Enum.filter(wanted, fn {date, _at} -> Map.has_key?(by_date, date) end)
    now = DateTime.utc_now()

    with :ok <- venue_free(next, followed ++ new, Enum.map(rows, & &1.id)),
         :ok <-
           series_holds_bookings(
             Enum.filter(rows, &Map.has_key?(wanted_by_date, &1.series_local_date)),
             next.capacity
           ),
         :ok <-
           deferred(fn ->
             Enum.each(
               rows,
               &rewrite!(&1, Map.fetch(wanted_by_date, &1.series_local_date), next, actor_id, now)
             )

             insert_all!(next, template, new, actor_id)
           end) do
      {:ok, length(rows) + length(new)}
    end
  end

  # SF-99: a class never gets fewer places than its confirmed bookings.
  defp holds_bookings(%ClassOccurrence{capacity: capacity}, capacity), do: :ok

  defp holds_bookings(%ClassOccurrence{id: id}, capacity) do
    confirmed = Map.get(Bookings.confirmed_counts([id]), id, 0)

    if capacity >= confirmed,
      do: :ok,
      else:
        {:error,
         {:conflict,
          %{class_occurrence: "capacity_below_bookings", confirmed_bookings: confirmed}}}
  end

  defp series_holds_bookings(rows, capacity) do
    counts = Bookings.confirmed_counts(Enum.map(rows, & &1.id))

    case rows |> Enum.filter(&(Map.get(counts, &1.id, 0) > capacity)) do
      [] ->
        :ok

      over ->
        {:error,
         {:conflict,
          %{
            class_series: "capacity_below_bookings",
            local_dates: over |> Enum.map(&Date.to_iso8601(&1.series_local_date)) |> Enum.sort()
          }}}
    end
  end

  defp rewrite!(row, {:ok, at}, next, _actor_id, now), do: follow!(row, next, at, now)
  defp rewrite!(row, :error, _next, actor_id, now), do: drop!(row, actor_id, now)

  defp follow!(%ClassOccurrence{} = row, next, at, now) do
    changes = %{
      status: :scheduled,
      cancelled_at: nil,
      cancel_reason: nil,
      cancelled_by_user_id: nil,
      starts_at: at,
      ends_at: DateTime.add(at, next.duration_minutes * 60, :second),
      duration_minutes: next.duration_minutes,
      venue_id: next.venue_id,
      instructor_staff_membership_id: next.instructor_staff_membership_id,
      capacity: next.capacity
    }

    changed = Map.reject(changes, fn {key, value} -> Map.get(row, key) == value end)

    instructor =
      if Map.has_key?(changed, :instructor_staff_membership_id),
        do: %{instructor_released_at: nil},
        else: %{}

    if changed != %{} do
      row
      |> Changeset.change(
        changed
        |> Map.merge(instructor)
        |> Map.merge(%{revision: row.revision + 1, updated_at: now})
      )
      |> Repo.update!(@unlogged)
    end
  end

  defp drop!(%ClassOccurrence{status: :cancelled}, _actor_id, _now), do: :ok

  defp drop!(%ClassOccurrence{} = row, actor_id, now) do
    Bookings.release_occurrences!(row.gym_id, [row.id], actor_id, now)

    row
    |> Changeset.change(
      status: :cancelled,
      cancelled_at: now,
      cancel_reason: :series_changed,
      cancelled_by_user_id: actor_id,
      revision: row.revision + 1,
      updated_at: now
    )
    |> Repo.update!(@unlogged)
  end

  defp new_occurrence(series, template, date, at, actor_id) do
    %ClassOccurrence{
      gym_id: series.gym_id,
      template_id: series.template_id,
      series_id: series.id,
      series_local_date: date,
      venue_id: series.venue_id,
      instructor_staff_membership_id: series.instructor_staff_membership_id,
      title: template.title,
      time_zone: series.time_zone,
      starts_at: at,
      ends_at: DateTime.add(at, series.duration_minutes * 60, :second),
      duration_minutes: series.duration_minutes,
      capacity: series.capacity,
      created_by_user_id: actor_id
    }
  end

  # The rule's dates whose class starts in the future, and the skipped ones.
  defp expand(%ClassSeries{} = series) do
    clock = Clock.utc_now()

    series.starts_on
    |> Scheduling.weekly(
      series.ends_on,
      series.weekdays,
      series.local_start_time,
      series.time_zone
    )
    |> Enum.reduce({[], []}, fn
      {date, {:ok, at}}, {wanted, skipped} ->
        if DateTime.compare(at, clock) == :gt,
          do: {[{date, usec(at)} | wanted], skipped},
          else: {wanted, skipped}

      {date, {:error, reason}}, {wanted, skipped} ->
        {wanted, [%{local_date: date, reason: reason} | skipped]}
    end)
    |> then(fn {wanted, skipped} -> {Enum.reverse(wanted), Enum.reverse(skipped)} end)
  end

  defp some([]),
    do:
      {:error,
       Schedule.field_error(:weekdays, "schedule no class from now on in the date range", :length)}

  defp some(_wanted), do: :ok

  # Runs `fun` with the overlap constraints deferred, then checks them: a
  # conflict anywhere rolls the whole change back.
  defp deferred(fun) do
    %Postgrex.Result{} = Repo.query!("#{@deferred} DEFERRED", [], @unlogged)
    fun.()

    try do
      %Postgrex.Result{} = Repo.query!("#{@deferred} IMMEDIATE", [], @unlogged)
      :ok
    rescue
      error in Postgrex.Error ->
        if error.postgres[:code] == :exclusion_violation,
          do: {:error, overlap(error.postgres[:constraint])},
          else: reraise(error, __STACKTRACE__)
    end
  end

  defp overlap("gym_class_occurrences_venue_overlap"),
    do: {:conflict, %{schedule: "venue_unavailable"}}

  defp overlap(_instructor), do: {:conflict, %{schedule: "instructor_unavailable"}}

  # This gym's own classes in the venue that a series would overlap, by the
  # series' dates (the constraint stays the authority; this names the dates).
  defp venue_free(_series, [], _rewritten), do: :ok

  defp venue_free(%ClassSeries{} = series, wanted, rewritten) do
    {dates, starts} = Enum.unzip(wanted)
    ends = Enum.map(starts, &DateTime.add(&1, series.duration_minutes * 60, :second))

    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT w.local_date
          FROM unnest($1::date[], $2::timestamp[], $3::timestamp[]) AS w(local_date, s, e)
          JOIN gym_class_occurrences o
            ON o.venue_id = $4 AND o.status = 'scheduled'
           AND tsrange(o.starts_at, o.ends_at, '[)') && tsrange(w.s, w.e, '[)')
         WHERE NOT (o.id = ANY($5::uuid[]))
         ORDER BY w.local_date
        """,
        [
          dates,
          Enum.map(starts, &DateTime.to_naive/1),
          Enum.map(ends, &DateTime.to_naive/1),
          Ecto.UUID.dump!(series.venue_id),
          Enum.map(rewritten, &Ecto.UUID.dump!/1)
        ],
        @unlogged
      )

    case rows do
      [] ->
        :ok

      taken ->
        {:error,
         {:conflict,
          %{schedule: "venue_unavailable", local_dates: Enum.map(taken, &Date.to_iso8601(hd(&1)))}}}
    end
  end

  defp window(series, mode \\ :create)

  defp window(%ClassSeries{} = series, mode) do
    today = series.time_zone |> then(&Scheduling.local(Clock.utc_now(), &1)) |> elem(0)

    cond do
      mode == :create and Date.compare(series.starts_on, today) == :lt ->
        {:error, Schedule.field_error(:starts_on, "must not be in the past", :number)}

      Date.compare(series.ends_on, series.starts_on) == :lt ->
        {:error, Schedule.field_error(:ends_on, "must not be before starts_on", :number)}

      Date.diff(series.ends_on, series.starts_on) > 365 ->
        {:error,
         Schedule.field_error(:ends_on, "must be at most a year after starts_on", :number)}

      Date.diff(series.ends_on, today) > 366 ->
        {:error, Schedule.field_error(:ends_on, "must be at most a year from today", :number)}

      mode == :update and Date.compare(series.ends_on, today) == :lt ->
        {:error, Schedule.field_error(:ends_on, "must not be in the past", :number)}

      true ->
        :ok
    end
  end

  defp series_active(%ClassSeries{status: :active}), do: :ok
  defp series_active(%ClassSeries{}), do: {:error, {:conflict, %{class_series: "cancelled"}}}

  ## Instructors and first run

  @doc false
  # Takes a staff membership that can no longer instruct (ended, or now
  # front desk) off every class of the gym still to come, its series and
  # template defaults, inside the caller's transaction (which holds the gym
  # row). Past classes keep their instructor.
  @spec release_instructor!(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: :ok
  def release_instructor!(gym_id, membership_id, actor_user_id, now) do
    true = Repo.in_transaction?()
    clock = Clock.utc_now()

    {count, _} =
      Repo.update_all(
        from(o in ClassOccurrence,
          where:
            o.gym_id == ^gym_id and o.instructor_staff_membership_id == ^membership_id and
              o.status == :scheduled and o.starts_at > ^clock,
          update: [
            set: [
              instructor_staff_membership_id: nil,
              instructor_released_at: ^now,
              updated_at: ^now
            ],
            inc: [revision: 1]
          ]
        ),
        [],
        @unlogged
      )

    Repo.update_all(
      from(s in ClassSeries,
        where:
          s.gym_id == ^gym_id and s.instructor_staff_membership_id == ^membership_id and
            s.status == :active,
        update: [set: [instructor_staff_membership_id: nil, updated_at: ^now], inc: [revision: 1]]
      ),
      [],
      @unlogged
    )

    Repo.update_all(
      from(t in ClassTemplate,
        where: t.gym_id == ^gym_id and t.default_instructor_staff_membership_id == ^membership_id,
        update: [
          set: [default_instructor_staff_membership_id: nil, updated_at: ^now],
          inc: [revision: 1]
        ]
      ),
      [],
      @unlogged
    )

    if count > 0 do
      audit!(
        gym_id,
        actor_user_id,
        :class_instructor_released,
        %{staff_membership_id: membership_id, occurrence_count: count},
        now
      )
    end

    :ok
  end

  @doc false
  # SF-90 `add_class`: the gym has scheduled a class (any occurrence was
  # ever written; a template alone is not a class, and a later cancellation
  # keeps the fact).
  @spec any_class?(Ecto.UUID.t()) :: boolean()
  def any_class?(gym_id),
    do: Repo.exists?(from(o in ClassOccurrence, where: o.gym_id == ^gym_id), @unlogged)

  ## Lookups and checks

  defp fetch_occurrence(gym_id, id, lock?) do
    case Access.cast_id(id) do
      {:ok, id} ->
        query = from(o in ClassOccurrence, where: o.id == ^id and o.gym_id == ^gym_id)
        query = if lock?, do: from(o in query, lock: "FOR UPDATE"), else: query
        Repo.one(query, @unlogged)

      :error ->
        nil
    end
  end

  defp fetch_series(gym_id, id, lock?) do
    case Access.cast_id(id) do
      {:ok, id} ->
        query = from(s in ClassSeries, where: s.id == ^id and s.gym_id == ^gym_id)
        query = if lock?, do: from(s in query, lock: "FOR UPDATE"), else: query
        Repo.one(query, @unlogged)

      :error ->
        nil
    end
  end

  defp template(gym_id, template_id) do
    case ClassTemplates.fetch(gym_id, template_id, false) do
      %ClassTemplate{status: :active} = template ->
        {:ok, template}

      %ClassTemplate{} ->
        {:error, Schedule.field_error(:template_id, "is archived", :inclusion)}

      nil ->
        {:error,
         Schedule.field_error(:template_id, "is not a class template of this gym", :inclusion)}
    end
  end

  defp venue(_gym_id, nil),
    do: {:error, Schedule.field_error(:venue_id, "can't be blank", :required)}

  defp venue(gym_id, venue_id) do
    case Venues.fetch(gym_id, venue_id, false) do
      %Venue{status: :active} = venue ->
        {:ok, venue}

      _ ->
        {:error,
         Schedule.field_error(:venue_id, "is not an active venue of this gym", :inclusion)}
    end
  end

  defp same_zone(%Venue{time_zone: zone}, %{time_zone: zone}), do: :ok

  defp same_zone(_venue, _scheduled),
    do: {:error, Schedule.field_error(:venue_id, "is in another time zone", :inclusion)}

  defp fits(%Venue{capacity: nil}, _capacity), do: :ok
  defp fits(%Venue{capacity: max}, capacity) when capacity <= max, do: :ok

  defp fits(_venue, _capacity),
    do: {:error, Schedule.field_error(:capacity, "is more than the venue holds", :number)}

  # An explicit `null` removes; an absent key keeps `fallback`.
  defp pick(attrs, params, key, fallback) do
    if Map.has_key?(attrs, Atom.to_string(key)), do: params[key], else: fallback
  end

  # A one-time instant: the explicit offset is the zone's at that instant,
  # in the future, at most a year ahead.
  defp instant(raw, %DateTime{} = at, zone) do
    clock = Clock.utc_now()

    cond do
      match?({:error, :missing_offset}, Scheduling.parse_instant(raw)) ->
        {:error, Schedule.field_error(:starts_at, "needs an explicit UTC offset", :cast)}

      not offset_ok?(raw, at, zone) ->
        {:error,
         Schedule.field_error(:starts_at, "has an offset that is not the time zone's", :format)}

      DateTime.compare(at, clock) != :gt ->
        {:error, Schedule.field_error(:starts_at, "must be in the future", :number)}

      DateTime.diff(at, clock, :day) > 366 ->
        {:error, Schedule.field_error(:starts_at, "must be at most a year ahead", :number)}

      true ->
        {:ok, usec(at)}
    end
  end

  defp instant(_raw, _at, _zone),
    do: {:error, Schedule.field_error(:starts_at, "can't be blank", :required)}

  defp offset_ok?(raw, at, zone) do
    case Scheduling.parse_instant(raw) do
      {:ok, _at, offset} -> Scheduling.offset_matches?(at, offset, zone)
      _ -> false
    end
  end

  defp usec(%DateTime{microsecond: {us, _}} = at), do: %{at | microsecond: {us, 6}}

  defp constrained(changeset) do
    changeset
    |> Changeset.exclusion_constraint(:starts_at, name: :gym_class_occurrences_venue_overlap)
    |> Changeset.exclusion_constraint(:instructor_staff_membership_id,
      name: :gym_class_occurrences_instructor_overlap
    )
    |> Changeset.check_constraint(:instructor_staff_membership_id,
      name: :gym_class_instructor_eligible,
      message: "is not an instructor of this gym"
    )
    |> Changeset.check_constraint(:venue_id,
      name: :gym_class_occurrences_venue_active,
      message: "is not an active venue of this gym"
    )
    |> Changeset.check_constraint(:capacity,
      name: :gym_class_occurrences_venue_capacity,
      message: "is more than the venue holds"
    )
  end

  defp constraint_error(%Changeset{errors: errors} = changeset) do
    cond do
      match?({_, [{:constraint, :exclusion} | _]}, errors[:starts_at]) ->
        {:conflict, %{schedule: "venue_unavailable"}}

      match?({_, [{:constraint, :exclusion} | _]}, errors[:instructor_staff_membership_id]) ->
        {:conflict, %{schedule: "instructor_unavailable"}}

      true ->
        changeset
    end
  end

  ## Params

  defp occurrence_params(attrs) do
    types = %{
      client_request_id: Ecto.UUID,
      template_id: Ecto.UUID,
      starts_at: :utc_datetime_usec,
      venue_id: Ecto.UUID,
      instructor_staff_membership_id: Ecto.UUID,
      duration_minutes: :integer,
      capacity: :integer
    }

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required([:client_request_id, :template_id, :starts_at])
    |> Schedule.reject_unknown(attrs, Enum.map(Map.keys(types), &Atom.to_string/1))
    |> numbers()
    |> Schedule.apply()
  end

  defp reschedule_params(attrs) do
    types = %{
      starts_at: :utc_datetime_usec,
      venue_id: Ecto.UUID,
      instructor_staff_membership_id: Ecto.UUID,
      duration_minutes: :integer,
      capacity: :integer
    }

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Schedule.reject_unknown(attrs, [
      "expected_revision" | Enum.map(Map.keys(types), &Atom.to_string/1)
    ])
    |> numbers()
    |> required_if_present(attrs, [:starts_at, :venue_id, :duration_minutes, :capacity])
    |> Schedule.apply()
  end

  defp series_params(attrs, current) do
    types = %{
      client_request_id: Ecto.UUID,
      template_id: Ecto.UUID,
      venue_id: Ecto.UUID,
      instructor_staff_membership_id: Ecto.UUID,
      weekdays: {:array, :integer},
      local_start_time: :time,
      duration_minutes: :integer,
      capacity: :integer,
      starts_on: :date,
      ends_on: :date
    }

    {permitted, required, allowed} =
      if current == nil,
        do:
          {Map.keys(types),
           [:client_request_id, :template_id, :weekdays, :local_start_time, :starts_on, :ends_on],
           Enum.map(Map.keys(types), &Atom.to_string/1)},
        else:
          {[
             :venue_id,
             :instructor_staff_membership_id,
             :weekdays,
             :local_start_time,
             :duration_minutes,
             :capacity,
             :ends_on
           ], [],
           ~w(expected_revision venue_id instructor_staff_membership_id weekdays local_start_time
              duration_minutes capacity ends_on)}

    {%{}, types}
    |> Changeset.cast(attrs, permitted)
    |> Changeset.validate_required(required)
    |> Schedule.reject_unknown(attrs, allowed)
    |> numbers()
    |> Changeset.update_change(:weekdays, &(&1 |> Enum.uniq() |> Enum.sort()))
    |> Changeset.validate_length(:weekdays, min: 1, max: 7)
    |> Changeset.validate_subset(:weekdays, 1..7)
    |> Changeset.update_change(:local_start_time, &%{&1 | second: 0, microsecond: {0, 0}})
    |> required_if_present(attrs, [
      :weekdays,
      :local_start_time,
      :venue_id,
      :duration_minutes,
      :capacity,
      :ends_on
    ])
    |> Schedule.apply()
  end

  defp numbers(changeset) do
    changeset
    |> Changeset.validate_number(:duration_minutes,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: 480
    )
    |> Changeset.validate_number(:capacity,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 500
    )
  end

  # A field that may be omitted, but not sent as `null`.
  defp required_if_present(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      if Map.has_key?(attrs, Atom.to_string(field)) and is_nil(attrs[Atom.to_string(field)]),
        do: Changeset.add_error(acc, field, "can't be blank", validation: :required),
        else: acc
    end)
  end

  defp list_filters(params) do
    types = %{
      from: :string,
      to: :string,
      venue_id: Ecto.UUID,
      instructor_staff_membership_id: Ecto.UUID,
      template_id: Ecto.UUID,
      series_id: Ecto.UUID
    }

    changeset =
      {%{}, types}
      |> Changeset.cast(params, Map.keys(types))
      |> Changeset.validate_required([:from, :to])

    with %Changeset{valid?: true} <- changeset,
         {:ok, from} <- bound(changeset, :from),
         {:ok, to} <- bound(changeset, :to),
         :ok <- range(from, to) do
      {:ok, changeset |> Changeset.apply_changes() |> Map.merge(%{from: from, to: to})}
    else
      %Changeset{} = invalid -> {:error, invalid}
      {:error, _} = error -> error
    end
  end

  defp bound(changeset, field) do
    case Scheduling.parse_instant(Changeset.get_field(changeset, field)) do
      {:ok, at, _offset} ->
        {:ok, usec(at)}

      _ ->
        {:error, Schedule.field_error(field, "must be an RFC 3339 instant with an offset", :cast)}
    end
  end

  defp range(from, to) do
    cond do
      DateTime.compare(to, from) != :gt ->
        {:error, Schedule.field_error(:to, "must be after from", :number)}

      DateTime.diff(to, from, :second) > @max_days * 86_400 ->
        {:error,
         Schedule.field_error(:to, "must be at most #{@max_days} days after from", :number)}

      true ->
        :ok
    end
  end

  @doc false
  # The `from`/`to` window of a class list (SF-99 member classes): RFC 3339
  # instants at most #{@max_days} days apart.
  @spec class_window(map()) :: {:ok, %{from: DateTime.t(), to: DateTime.t()}} | {:error, term()}
  def class_window(params) do
    with {:ok, filters} <- list_filters(Map.take(params, ["from", "to"])),
         do: {:ok, Map.take(filters, [:from, :to])}
  end

  @doc false
  # The staff views of classes (wall times computed in their zone), for SF-99.
  @spec views([ClassOccurrence.t()]) :: [map()]
  def views(rows), do: occurrence_views(rows)

  ## Views

  defp occurrence_view(%ClassOccurrence{} = occurrence), do: hd(occurrence_views([occurrence]))

  defp occurrence_views([]), do: []

  defp occurrence_views(rows) do
    instructors = Schedule.instructors(Enum.map(rows, & &1.instructor_staff_membership_id))
    venue_ids = rows |> Enum.map(& &1.venue_id) |> Enum.uniq()

    venues =
      Repo.all(from(v in Venue, where: v.id in ^venue_ids, select: {v.id, v.name}), @unlogged)
      |> Map.new()

    locals = locals(rows)

    Enum.map(rows, fn o ->
      {local_start, local_end} = Map.fetch!(locals, o.id)

      %{
        occurrence_id: o.id,
        gym_id: o.gym_id,
        template_id: o.template_id,
        series_id: o.series_id,
        series_local_date: o.series_local_date,
        title: o.title,
        status: o.status,
        starts_at: o.starts_at,
        ends_at: o.ends_at,
        time_zone: o.time_zone,
        local_starts_at: local_start,
        local_ends_at: local_end,
        utc_offset_minutes:
          div(NaiveDateTime.diff(local_start, DateTime.to_naive(o.starts_at)), 60),
        duration_minutes: o.duration_minutes,
        capacity: o.capacity,
        venue: %{venue_id: o.venue_id, name: Map.get(venues, o.venue_id)},
        instructor: Map.get(instructors, o.instructor_staff_membership_id),
        needs_instructor: o.instructor_released_at != nil,
        rescheduled: o.rescheduled_at != nil,
        cancelled_at: o.cancelled_at,
        cancel_reason: o.cancel_reason,
        revision: o.revision,
        created_at: o.inserted_at,
        updated_at: o.updated_at
      }
    end)
  end

  # The wall-clock start and end of each class in its own zone.
  defp locals(rows) do
    ids = Enum.map(rows, &Ecto.UUID.dump!(&1.id))

    %{rows: locals} =
      Repo.query!(
        """
        SELECT id, (starts_at AT TIME ZONE 'UTC') AT TIME ZONE time_zone,
               (ends_at AT TIME ZONE 'UTC') AT TIME ZONE time_zone
          FROM gym_class_occurrences WHERE id = ANY($1::uuid[])
        """,
        [ids],
        @unlogged
      )

    Map.new(locals, fn [id, local_start, local_end] ->
      {Ecto.UUID.load!(id), {truncate(local_start), truncate(local_end)}}
    end)
  end

  defp truncate(%NaiveDateTime{} = at), do: NaiveDateTime.truncate(at, :second)

  defp series_view(%ClassSeries{} = series, detail?) do
    template = Repo.get!(ClassTemplate, series.template_id, @unlogged)
    venue = Repo.get!(Venue, series.venue_id, @unlogged)
    instructors = Schedule.instructors([series.instructor_staff_membership_id])

    base = %{
      series_id: series.id,
      gym_id: series.gym_id,
      template_id: series.template_id,
      title: template.title,
      venue: %{venue_id: venue.id, name: venue.name},
      instructor: Map.get(instructors, series.instructor_staff_membership_id),
      time_zone: series.time_zone,
      weekdays: series.weekdays,
      local_start_time:
        series.local_start_time
        |> Time.truncate(:second)
        |> Time.to_iso8601()
        |> binary_part(0, 5),
      duration_minutes: series.duration_minutes,
      capacity: series.capacity,
      starts_on: series.starts_on,
      ends_on: series.ends_on,
      status: series.status,
      revision: series.revision,
      created_at: series.inserted_at,
      updated_at: series.updated_at
    }

    if detail?, do: Map.merge(base, series_detail(series)), else: base
  end

  defp series_detail(series) do
    counts =
      Repo.all(
        from(o in ClassOccurrence,
          where: o.series_id == ^series.id,
          group_by: o.status,
          select: {o.status, count(o.id)}
        ),
        @unlogged
      )
      |> Map.new()

    skipped =
      series.starts_on
      |> Scheduling.weekly(
        series.ends_on,
        series.weekdays,
        series.local_start_time,
        series.time_zone
      )
      |> Enum.flat_map(fn
        {date, {:error, reason}} -> [%{local_date: date, reason: reason}]
        _ -> []
      end)

    %{
      scheduled_count: Map.get(counts, :scheduled, 0),
      cancelled_count: Map.get(counts, :cancelled, 0),
      skipped_dates: skipped
    }
  end

  defp audit!(gym_id, actor_id, event, ids, now),
    do:
      Audit.record!(
        Map.merge(%{gym_id: gym_id, actor_user_id: actor_id, event_type: event}, ids),
        now
      )
end
