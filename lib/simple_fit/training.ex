defmodule SimpleFit.Training do
  @moduledoc """
  Training sessions (ADR 0023; SF-49 §8): one planned training a coach
  assigns to one fighter within one active Coach–Fighter relationship.

  ## Who may do what

    * **Coach** (completed coach profile, Coach–Fighter sharing ready): create
      a session under one of their active relationships whose accepted
      disclosure still applies; change and cancel it while it is planned and
      the relationship is active; read the sessions of their active
      relationships. A former coach reads nothing (product decision
      2026-10-20). Relationships are authorized only by `SimpleFit.Coaching`.
    * **Fighter** (completed fighter profile): reads every session assigned to
      them and completes their planned ones from their start onwards
      (`complete_session/3`, SF-63), whatever the relationship (an ended one
      included) or the sharing gate: it is their own training history. The
      former coach learns nothing of it (they read nothing after an end).

  Foreign, unknown, malformed and no-longer-authorized ids all answer
  `:not_found` (no existence oracle).

  ## Lifecycle

  `:planned` → `:cancelled` (coach, or the system when the relationship ends)
  or `:completed` (the fighter, `complete_session/3`). Terminal states never change; the database rejects
  any other transition and any change to owners or the request key.

  ## Scheduling

  `starts_at` is an instant (RFC 3339 with an explicit offset; stored UTC)
  and `time_zone` an IANA id validated against PostgreSQL's zone data
  (SF-49 §8.3; no Elixir zone database). The API does no wall-clock
  arithmetic: a client resolves the coach's wall time to an instant. A
  non-UTC offset must be the zone's offset at that instant, so a local time
  that does not exist (spring-forward gap) cannot be sent with a stale
  offset, and both instants of a repeated (autumn) local time stay distinct.
  `starts_at` lies between one day before and one year after now when it is
  set.

  ## Idempotency

  A create carries `client_request_id` (a UUID the client picks per create and
  repeats on a retry). The first create with a key inserts; any later one with
  the same key returns that session unchanged (`:existing`), or `409 conflict`
  `client_request_id: reused` when the key names another relationship.
  Concurrent creates with one key insert once (unique index).

  ## Locks

  The relationship row first (`FOR SHARE` for session work, `FOR UPDATE` for
  an end), then session rows (`FOR UPDATE`). A future operation on a session
  alone (SF-63 completion) locks the session only. Ending a relationship
  cancels its planned future sessions in the end transaction
  (`cancel_for_relationship/2`), so no ended relationship ever has an
  actionable session and no session is created after an end commits.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaching, Fighters, Repo}
  alias SimpleFit.Training.TrainingSession

  # Session rows carry the coach's words about a person's training.
  @unlogged [log: false]

  @default_limit 50
  @max_limit 100

  @create_keys ~w(relationship_id client_request_id title training_type starts_at time_zone duration_minutes notes)
  @plan_keys ~w(title training_type starts_at time_zone duration_minutes notes)

  @typedoc "A session as one side sees it (`:coach` or `:fighter` projection)."
  @type view :: map()

  @typedoc "A page of views and the cursor of the next one (`nil` on the last page)."
  @type page :: %{entries: [view()], next_cursor: String.t() | nil}

  @type error ::
          :not_found | {:conflict, map()} | Changeset.t()

  ## Coach

  @doc """
  Creates a planned session under one of the coach's relationships
  (`attrs`, string keys: `relationship_id`, `client_request_id`, `title`,
  `training_type`, `starts_at`, `time_zone`, `duration_minutes`, optional
  `notes`; nothing else). The fighter is the relationship's. Returns the
  coach's view and `:created`, or `:existing` for a repeated
  `client_request_id`.
  """
  @spec create_session(User.t(), map()) :: {:ok, view(), :created | :existing} | {:error, error()}
  def create_session(%User{} = user, attrs) when is_map(attrs) do
    with {:ok, coach} <- Coaching.training_coach(user),
         {:ok, request} <- create_request(attrs) do
      Repo.transaction(fn -> create_locked(coach.id, request) end, @unlogged)
      |> case do
        {:ok, {session, outcome}} ->
          emit(:created, %{outcome: outcome})
          {:ok, coach_view(session), outcome}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_locked(coach_id, request) do
    with {:ok, relationship} <-
           Coaching.lock_training_relationship(coach_id, request.relationship_id,
             require: :disclosing
           ),
         nil <- by_request(coach_id, request.client_request_id),
         {:ok, %TrainingSession{} = session} <- insert(relationship, request) do
      {session, :created}
    else
      %TrainingSession{} = existing -> replay(existing, request)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # ON CONFLICT DO NOTHING: a concurrent create with the same key waits for
  # the first transaction and then inserts nothing. The committed row for the
  # key is read back: ours (`:created`) or the other request's (`:existing`).
  defp insert(relationship, request) do
    %TrainingSession{id: id} =
      %TrainingSession{
        id: Ecto.UUID.generate(),
        coach_fighter_relationship_id: relationship.id,
        coach_profile_id: relationship.coach_profile_id,
        fighter_profile_id: relationship.fighter_profile_id,
        client_request_id: request.client_request_id,
        status: :planned
      }
      |> Changeset.change(request.plan)
      |> Repo.insert!(
        [on_conflict: :nothing, conflict_target: [:coach_profile_id, :client_request_id]] ++
          @unlogged
      )

    case by_request(relationship.coach_profile_id, request.client_request_id) do
      %TrainingSession{id: ^id} = session -> {:ok, session}
      %TrainingSession{} = existing -> existing
    end
  end

  defp replay(%TrainingSession{} = existing, request) do
    if existing.coach_fighter_relationship_id == request.relationship_id,
      do: {existing, :existing},
      else: Repo.rollback({:conflict, %{client_request_id: "reused"}})
  end

  defp by_request(coach_id, client_request_id) do
    Repo.one(
      from(s in TrainingSession,
        where: s.coach_profile_id == ^coach_id and s.client_request_id == ^client_request_id
      ),
      @unlogged
    )
  end

  @doc """
  Changes the plan of one of the coach's planned sessions (`attrs`: any of
  `title`, `training_type`, `starts_at`, `time_zone`, `duration_minutes`,
  `notes`; nothing else). `409 conflict` (`status`) once it is completed or
  cancelled.
  """
  @spec update_session(User.t(), term(), map()) :: {:ok, view()} | {:error, error()}
  def update_session(%User{} = user, id, attrs) when is_map(attrs) do
    with {:ok, coach} <- Coaching.training_coach(user),
         {:ok, id} <- uuid(id),
         :ok <- only_keys(attrs, @plan_keys) do
      Repo.transaction(fn -> update_locked(coach.id, id, attrs) end, @unlogged)
      |> view(&coach_view/1)
    end
  end

  defp update_locked(coach_id, id, attrs) do
    session = lock_coach_session(coach_id, id, :disclosing)
    planned!(session)

    changeset = TrainingSession.plan_changeset(session, attrs) |> validate_schedule()

    if changeset.valid? do
      emit(:updated, %{})
      Repo.update!(changeset, @unlogged)
    else
      Repo.rollback(changeset)
    end
  end

  @doc """
  Cancels one of the coach's planned sessions. Repeating it returns the
  cancelled session unchanged; a completed one is `409 conflict` (`status`).
  """
  @spec cancel_session(User.t(), term()) :: {:ok, view()} | {:error, error()}
  def cancel_session(%User{} = user, id) do
    with {:ok, coach} <- Coaching.training_coach(user),
         {:ok, id} <- uuid(id) do
      Repo.transaction(fn -> cancel_locked(coach.id, id) end, @unlogged)
      |> view(&coach_view/1)
    end
  end

  defp cancel_locked(coach_id, id) do
    case lock_coach_session(coach_id, id, :active) do
      %TrainingSession{status: :cancelled} = session ->
        session

      %TrainingSession{status: :planned} = session ->
        emit(:cancelled, %{cancelled_by: :coach})

        session
        |> Changeset.change(status: :cancelled, cancelled_at: now(), cancelled_by: :coach)
        |> Repo.update!(@unlogged)

      %TrainingSession{status: status} ->
        Repo.rollback({:conflict, %{status: Atom.to_string(status)}})
    end
  end

  # Relationship row first (FOR SHARE, through Coaching), then the session.
  defp lock_coach_session(coach_id, id, requirement) do
    with %{coach_fighter_relationship_id: relationship_id} <-
           Repo.one(
             from(s in TrainingSession,
               where: s.id == ^id and s.coach_profile_id == ^coach_id,
               select: %{coach_fighter_relationship_id: s.coach_fighter_relationship_id}
             ),
             @unlogged
           ),
         {:ok, _relationship} <-
           Coaching.lock_training_relationship(coach_id, relationship_id, require: requirement),
         %TrainingSession{} = session <-
           Repo.one(
             from(s in TrainingSession,
               where: s.id == ^id and s.coach_profile_id == ^coach_id,
               lock: "FOR UPDATE"
             ),
             @unlogged
           ) do
      session
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp planned!(%TrainingSession{status: :planned}), do: :ok

  defp planned!(%TrainingSession{status: status}),
    do: Repo.rollback({:conflict, %{status: Atom.to_string(status)}})

  @doc """
  The sessions of the coach's active relationships, by start (then id).
  Params (string keys): `view` (`upcoming` | `history`, server time; see
  `page/3`), `status`, `from`, `to` (instants; `from` ≤ `starts_at` < `to`),
  `relationship_id`, `limit` (1..100, default 50), `cursor` (valid only for
  the same `view`).
  """
  @spec list_coach_sessions(User.t(), map()) ::
          {:ok, page()} | {:error, :not_found | Changeset.t()}
  def list_coach_sessions(%User{} = user, params) when is_map(params) do
    with {:ok, coach} <- Coaching.training_coach(user),
         {:ok, query} <- page_params(params, :coach) do
      {:ok, page(coach_scope(coach.id), query, &coach_views/1)}
    end
  end

  @doc "One session of the coach's active relationships."
  @spec get_coach_session(User.t(), term()) :: {:ok, view()} | {:error, :not_found}
  def get_coach_session(%User{} = user, id) do
    with {:ok, coach} <- Coaching.training_coach(user),
         {:ok, id} <- uuid(id),
         %TrainingSession{} = session <-
           Repo.one(from(s in coach_scope(coach.id), where: s.id == ^id), @unlogged),
         [view] <- coach_views([session]) do
      {:ok, view}
    else
      _ -> {:error, :not_found}
    end
  end

  defp coach_scope(coach_id) do
    from(s in TrainingSession,
      where:
        s.coach_profile_id == ^coach_id and
          s.coach_fighter_relationship_id in subquery(Coaching.active_relationship_ids(coach_id))
    )
  end

  ## Fighter

  @doc """
  The fighter's own sessions, by start (then id), from every relationship,
  whatever the sharing gate. Params as `list_coach_sessions/2` without
  `relationship_id`.
  """
  @spec list_fighter_sessions(User.t(), map()) ::
          {:ok, page()} | {:error, :not_found | Changeset.t()}
  def list_fighter_sessions(%User{} = user, params) when is_map(params) do
    with {:ok, fighter} <- completed(Fighters.get_profile(user)),
         {:ok, query} <- page_params(params, :fighter) do
      {:ok, page(fighter_scope(fighter.id), query, &fighter_views/1)}
    end
  end

  @doc "One of the fighter's own sessions."
  @spec get_fighter_session(User.t(), term()) :: {:ok, view()} | {:error, :not_found}
  def get_fighter_session(%User{} = user, id) do
    with {:ok, fighter} <- completed(Fighters.get_profile(user)),
         {:ok, id} <- uuid(id),
         %TrainingSession{} = session <-
           Repo.one(from(s in fighter_scope(fighter.id), where: s.id == ^id), @unlogged),
         [view] <- fighter_views([session]) do
      {:ok, view}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Completes one of the fighter's own planned sessions (SF-63; ADR 0023): the
  fighter confirms they did the training. The server sets `completed_at`
  (UTC) under the session's row lock; the request carries nothing else
  (`attrs` must be empty). Allowed from the session's start onwards, with no
  deadline, whatever the relationship (an ended one included) or the sharing
  gate: the session is the fighter's own training.

    * Repeated: the completed session, unchanged (its first `completed_at`).
    * Cancelled: `409 conflict` `status: cancelled`.
    * Not started yet: `409 conflict` `starts_at: not_started`.
    * Someone else's, unknown or malformed id, or no completed fighter
      profile: `:not_found`.

  Locks the session row only (never the relationship): an end or a coach's
  change waits for it or commits first, and exactly one terminal transition
  wins.
  """
  @spec complete_session(User.t(), term(), map()) :: {:ok, view()} | {:error, error()}
  def complete_session(%User{} = user, id, attrs \\ %{}) when is_map(attrs) do
    with {:ok, fighter} <- completed(Fighters.get_profile(user)),
         {:ok, id} <- uuid(id),
         :ok <- only_keys(attrs, []) do
      Repo.transaction(fn -> complete_locked(fighter.id, id) end, @unlogged)
      |> fighter_result()
    end
  end

  defp fighter_result({:ok, session}) do
    case fighter_views([session]) do
      [view] -> {:ok, view}
      [] -> {:error, :not_found}
    end
  end

  defp fighter_result({:error, reason}), do: {:error, reason}

  defp complete_locked(fighter_id, id) do
    from(s in fighter_scope(fighter_id), where: s.id == ^id, lock: "FOR UPDATE")
    |> Repo.one(@unlogged)
    |> case do
      nil ->
        Repo.rollback(:not_found)

      %TrainingSession{status: :completed} = session ->
        emit(:completed, %{outcome: :already_completed})
        session

      %TrainingSession{status: :cancelled} ->
        Repo.rollback({:conflict, %{status: "cancelled"}})

      %TrainingSession{status: :planned} = session ->
        now = now()

        if DateTime.compare(session.starts_at, now) == :gt do
          Repo.rollback({:conflict, %{starts_at: "not_started"}})
        else
          emit(:completed, %{outcome: :completed})

          session
          |> Changeset.change(status: :completed, completed_at: now)
          |> Repo.update!(@unlogged)
        end
    end
  end

  defp fighter_scope(fighter_id),
    do: from(s in TrainingSession, where: s.fighter_profile_id == ^fighter_id)

  ## Relationship end (called by SimpleFit.Coaching only)

  @doc """
  Cancels the relationship's planned sessions that start at or after `now`
  (`cancelled_by: :system`, `cancel_reason: :relationship_ended`). Called by
  `SimpleFit.Coaching` inside the end transaction, with the relationship row
  locked `FOR UPDATE`. Completed and cancelled sessions, and planned ones
  that started before the end, are left as they are (SF-49 §6.3, §6.4.4).
  """
  @spec cancel_for_relationship(Ecto.UUID.t(), DateTime.t()) :: non_neg_integer()
  def cancel_for_relationship(relationship_id, %DateTime{} = now) do
    {count, _} =
      Repo.update_all(
        from(s in TrainingSession,
          where:
            s.coach_fighter_relationship_id == ^relationship_id and s.status == :planned and
              s.starts_at >= ^now
        ),
        [
          set: [
            status: :cancelled,
            cancelled_at: now,
            cancelled_by: :system,
            cancel_reason: :relationship_ended,
            updated_at: now
          ]
        ],
        @unlogged
      )

    if count > 0, do: emit(:cancelled, %{cancelled_by: :system}, count)
    count
  end

  ## Requests

  defp create_request(attrs) do
    types = %{relationship_id: :string, client_request_id: Ecto.UUID}

    request =
      {%{}, types}
      |> Changeset.cast(attrs, Map.keys(types))
      |> Changeset.validate_required(Map.keys(types))

    plan =
      %TrainingSession{}
      |> TrainingSession.plan_changeset(attrs)
      |> validate_schedule()

    unknown = Map.keys(attrs) -- @create_keys

    if request.valid? and plan.valid? and unknown == [] do
      {:ok, Map.put(Changeset.apply_changes(request), :plan, plan.changes)}
    else
      {:error, merge_errors(plan, request, unknown)}
    end
  end

  defp merge_errors(plan, request, unknown) do
    errors =
      request.errors ++
        plan.errors ++ Enum.map(unknown, &{&1, {"is not a field of a training session", []}})

    %{plan | errors: errors, valid?: false}
  end

  defp only_keys(attrs, allowed) do
    case Map.keys(attrs) -- allowed do
      [] ->
        :ok

      unknown ->
        changeset = Changeset.change({%{}, %{}})

        errors =
          Enum.map(Enum.sort_by(unknown, &to_string/1), fn key ->
            {key, {"is not a field of a training session", []}}
          end)

        {:error, %{changeset | errors: errors, valid?: false}}
    end
  end

  # SF-49 §8.3: a real IANA zone; a set start lies in the allowed window and
  # its explicit offset (when not UTC) is the zone's offset at that instant.
  defp validate_schedule(%Changeset{} = changeset) do
    changeset
    |> validate_time_zone()
    |> validate_window()
    |> validate_offset()
  end

  defp validate_time_zone(changeset) do
    with zone when is_binary(zone) <- Changeset.get_change(changeset, :time_zone),
         [] <- Keyword.get_values(changeset.errors, :time_zone),
         false <- valid_time_zone?(zone) do
      Changeset.add_error(changeset, :time_zone, "is not a known IANA time zone")
    else
      _ -> changeset
    end
  end

  defp valid_time_zone?(zone) do
    %{rows: [[valid?]]} =
      Repo.query!("SELECT training_sessions_valid_time_zone($1)", [zone], @unlogged)

    valid?
  end

  defp validate_window(changeset) do
    case Changeset.get_change(changeset, :starts_at) do
      %DateTime{} = at ->
        now = now()

        if DateTime.compare(at, DateTime.add(now, -1, :day)) == :lt or
             DateTime.compare(at, DateTime.add(now, 365, :day)) == :gt,
           do:
             Changeset.add_error(
               changeset,
               :starts_at,
               "must be between one day ago and one year from now",
               validation: :number
             ),
           else: changeset

      _ ->
        changeset
    end
  end

  # `starts_at` arrives as RFC 3339 text (Ecto keeps only the instant, and
  # would read a time without an offset as UTC). The offset is required, and
  # a non-UTC one must match the zone at that instant: a stale offset means
  # the wall time was resolved in another zone or does not exist.
  defp validate_offset(changeset) do
    raw = Map.get(changeset.params || %{}, "starts_at")

    case (is_binary(raw) and Keyword.get_values(changeset.errors, :starts_at) == []) &&
           DateTime.from_iso8601(raw) do
      {:error, :missing_offset} ->
        Changeset.add_error(changeset, :starts_at, "needs an explicit UTC offset",
          type: :utc_datetime_usec
        )

      {:ok, at, offset} when offset != 0 ->
        if offset_mismatch?(changeset, at, offset),
          do:
            Changeset.add_error(
              changeset,
              :starts_at,
              "has an offset that is not the time zone's"
            ),
          else: changeset

      _ ->
        changeset
    end
  end

  defp offset_mismatch?(changeset, at, offset) do
    zone = Changeset.get_field(changeset, :time_zone)

    is_binary(zone) and Keyword.get_values(changeset.errors, :time_zone) == [] and
      zone_offset(at, zone) != offset
  end

  defp zone_offset(at, zone) do
    %{rows: [[seconds]]} =
      Repo.query!(
        "SELECT extract(epoch FROM ($1::timestamptz AT TIME ZONE $2) - ($1::timestamptz AT TIME ZONE 'UTC'))::integer",
        [at, zone],
        @unlogged
      )

    seconds
  end

  ## Views

  defp coach_views(sessions) do
    fighters = Coaching.training_fighters(Enum.map(sessions, & &1.coach_fighter_relationship_id))

    Enum.map(sessions, fn s ->
      Map.put(plan(s), :fighter, Map.get(fighters, s.coach_fighter_relationship_id))
    end)
  end

  defp coach_view(session), do: hd(coach_views([session]))

  defp fighter_views(sessions) do
    coaches = Coaching.training_coaches(Enum.map(sessions, & &1.coach_fighter_relationship_id))

    Enum.flat_map(sessions, fn s ->
      # The relationship (and so the session) went with a deleted coach.
      case Map.get(coaches, s.coach_fighter_relationship_id) do
        nil -> []
        coach -> [Map.merge(plan(s), coach)]
      end
    end)
  end

  defp plan(%TrainingSession{} = s) do
    Map.take(s, [
      :id,
      :title,
      :training_type,
      :starts_at,
      :time_zone,
      :duration_minutes,
      :notes,
      :status,
      :completed_at,
      :cancelled_at,
      :cancelled_by,
      :cancel_reason,
      :inserted_at,
      :updated_at
    ])
    |> Map.put(:relationship_id, s.coach_fighter_relationship_id)
  end

  defp view({:ok, session}, to_view), do: {:ok, to_view.(session)}
  defp view({:error, reason}, _to_view), do: {:error, reason}

  ## Paging

  defp page_params(params, side) do
    types = %{
      status: :string,
      from: :utc_datetime_usec,
      to: :utc_datetime_usec,
      relationship_id: Ecto.UUID,
      view: :string,
      limit: :integer,
      cursor: :string
    }

    keys = if side == :coach, do: Map.keys(types), else: Map.keys(types) -- [:relationship_id]

    changeset =
      {%{limit: @default_limit}, types}
      |> Changeset.cast(params, keys)
      |> Changeset.validate_inclusion(:status, ~w(planned completed cancelled))
      |> Changeset.validate_inclusion(:view, ~w(upcoming history))
      |> Changeset.validate_number(:limit,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: @max_limit
      )
      |> validate_range()
      |> validate_cursor()

    if changeset.valid? do
      query = Changeset.apply_changes(changeset)
      {:ok, Map.merge(query, %{view: view(query[:view]), now: now()})}
    else
      {:error, changeset}
    end
  end

  # Total: an unknown name is already a validation error (inclusion).
  defp view("upcoming"), do: :upcoming
  defp view("history"), do: :history
  defp view(_name), do: :all

  defp validate_range(changeset) do
    with %DateTime{} = from <- Changeset.get_field(changeset, :from),
         %DateTime{} = to <- Changeset.get_field(changeset, :to),
         :gt <- DateTime.compare(from, to) do
      Changeset.add_error(changeset, :to, "must not be before from")
    else
      _ -> changeset
    end
  end

  defp validate_cursor(changeset) do
    view = view(Changeset.get_field(changeset, :view))

    case Changeset.get_change(changeset, :cursor) do
      nil ->
        changeset

      cursor ->
        case decode_cursor(cursor, view) do
          {:ok, position} -> Changeset.put_change(changeset, :cursor, position)
          :error -> Changeset.add_error(changeset, :cursor, "is invalid", validation: :format)
        end
    end
  end

  # Views (SF-63), computed with the server's clock at the request:
  #   * `:all` (no `view`): every session, by start (earliest first);
  #   * `:upcoming`: planned and not yet over (`starts_at + duration > now`),
  #     earliest first: what the fighter can still do or is doing;
  #   * `:history`: completed, cancelled, and planned sessions already over
  #     (past due, never completed), newest first.
  # Ties are broken by id in the same direction. Each page is a keyset seek
  # from the cursor, so a traversal never repeats a session; a session whose
  # status or time changes between pages may move out of a view (it is then
  # skipped, never duplicated).
  defp page(scope, query, to_views) do
    rows =
      from(s in scope, limit: ^(query.limit + 1))
      |> order(query.view)
      |> within(query.view, query.now)
      |> filter(query)
      |> Repo.all(@unlogged)

    {rows, rest} = Enum.split(rows, query.limit)
    next = if rest == [], do: nil, else: encode_cursor(List.last(rows), query.view)
    %{entries: to_views.(rows), next_cursor: next}
  end

  defp order(q, :history), do: from(s in q, order_by: [desc: s.starts_at, desc: s.id])
  defp order(q, _view), do: from(s in q, order_by: [asc: s.starts_at, asc: s.id])

  defp within(q, :all, _now), do: q

  defp within(q, :upcoming, now),
    do:
      from(s in q,
        where:
          s.status == :planned and
            fragment("? + make_interval(mins => ?)", s.starts_at, s.duration_minutes) > ^now
      )

  defp within(q, :history, now),
    do:
      from(s in q,
        where:
          s.status != :planned or
            fragment("? + make_interval(mins => ?)", s.starts_at, s.duration_minutes) <= ^now
      )

  defp filter(q, query) do
    Enum.reduce([:status, :from, :to, :relationship_id], q, fn key, acc ->
      narrow(acc, key, Map.get(query, key))
    end)
    |> seek(query.view, query[:cursor])
  end

  defp narrow(q, _key, nil), do: q
  defp narrow(q, :status, status), do: from(s in q, where: s.status == ^status)
  defp narrow(q, :from, from), do: from(s in q, where: s.starts_at >= ^from)
  defp narrow(q, :to, to), do: from(s in q, where: s.starts_at < ^to)

  defp narrow(q, :relationship_id, id),
    do: from(s in q, where: s.coach_fighter_relationship_id == ^id)

  defp seek(q, _view, nil), do: q

  defp seek(q, :history, {at, id}),
    do: from(s in q, where: s.starts_at < ^at or (s.starts_at == ^at and s.id < ^id))

  defp seek(q, _view, {at, id}),
    do: from(s in q, where: s.starts_at > ^at or (s.starts_at == ^at and s.id > ^id))

  # An opaque position: the view it pages, then the start and id of the last
  # session shown. It grants nothing: every page is still scoped to the
  # caller's own sessions, and a cursor is only valid for its own view.
  defp encode_cursor(%TrainingSession{starts_at: at, id: id}, view),
    do: Base.url_encode64("#{view}|#{DateTime.to_unix(at, :microsecond)}|#{id}", padding: false)

  defp decode_cursor(cursor, view) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [micros, id] <- position(String.split(decoded, "|"), view),
         {micros, ""} <- Integer.parse(micros),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :error
    end
  end

  defp position([name, micros, id], view),
    do: if(name == Atom.to_string(view), do: [micros, id], else: :error)

  # SF-62 cursors (no view) page the whole list.
  defp position([micros, id], :all), do: [micros, id]
  defp position(_parts, _view), do: :error

  ## Helpers

  defp completed(%{onboarding_completed_at: %DateTime{}} = profile), do: {:ok, profile}
  defp completed(_profile), do: {:error, :not_found}

  defp uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp uuid(_id), do: {:error, :not_found}

  defp now, do: DateTime.utc_now()

  # Outcomes only: never a title, note, name or id.
  defp emit(event, metadata, count \\ 1),
    do: :telemetry.execute([:simple_fit, :training, :session, event], %{count: count}, metadata)
end
