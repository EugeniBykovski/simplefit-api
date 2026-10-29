defmodule SimpleFit.Gyms.FirstRun do
  @moduledoc """
  The gym first run (SF-90; ADR 0026 D-G21, ADR 0018 pattern): the owner's
  introduction to one completed gym, and the gym's setup checklist. Internal
  to `SimpleFit.Gyms`.

  Three different things, never conflated:

    * **Gym setup** (`gyms.setup_status`, SF-85) says the gym exists and is
      operational. The first run never changes it.
    * **The introduction** is the owner's own lifecycle at that gym: not
      started, in progress (started), then `completed` (finished) or
      `dismissed` (ended or skipped). Only these explicit actions are stored
      (`SimpleFit.Gyms.GymFirstRun`), per gym and owner, the same on every
      client. An outcome is final: it never reopens, and the other outcome is
      a conflict. Tour steps, highlights and replays are client-only.
    * **The checklist** is derived on every read from the gym's own records
      (`checklist/1`). Nothing in it is stored or settable by a client, and
      neither outcome of the introduction marks any item done.

  ## Who

  The owner (`manage_first_run`): GRW1/GR1 are the owner's opening week;
  managers, coaches and front desk get `forbidden` (their tour is OS4,
  later). The state belongs to the gym and the user together, so another
  gym, or a later owner of this one, starts fresh.

  A draft gym has no first run (`status: unavailable`); its transitions are
  a conflict (`setup_status: draft`).

  ## Locks

  Every call takes the gym row and the actor's membership with share locks
  (`Access.authorize_shared/3`, the SF-84 order), then the first-run row for
  update. An ownership transfer, a revocation or a draft discard (which lock
  the gym row for update) therefore commits entirely before or after; two
  transitions of one owner at one gym serialize on the first-run row.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{Access, Audit, Gym, GymFirstRun, StaffInvitation}
  alias SimpleFit.Repo

  @type status :: :unavailable | :not_started | :in_progress | :completed | :dismissed
  @type action :: :start | :complete | :dismiss

  @typedoc """
  A checklist item's state: `:completed` (a persisted fact of the gym),
  `:available` (the owner can do it now) or `:coming_later` (its domain does
  not exist yet; never actionable, never counted as missing).
  """
  @type item_status :: :completed | :available | :coming_later

  @type item :: %{key: atom(), status: item_status()}

  @type state :: %{
          gym_id: Ecto.UUID.t(),
          status: status(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          dismissed_at: DateTime.t() | nil,
          checklist: [item()]
        }

  @type error :: :not_found | :forbidden | {:conflict, map()} | Changeset.t()

  # The approved opening-week checklist (SF-82 C7, D-G21), in design order.
  # `create_gym` and `invite_staff` (SF-93) have their domains today; each
  # other item derives from its own domain when that ships (classes,
  # members and check-ins later), with no change to the first run.
  @checklist [:create_gym, :add_class, :invite_staff, :invite_members, :first_check_in]

  @doc "The checklist keys, in order."
  @spec checklist_keys() :: [atom()]
  def checklist_keys, do: @checklist

  @doc "The first run and checklist of a gym, for its owner."
  @spec get(User.t(), term()) :: {:ok, state()} | {:error, :not_found | :forbidden}
  def get(%User{id: user_id} = user, gym_id) when is_binary(user_id) do
    Repo.transaction(fn ->
      case Access.authorize_shared(user, gym_id, :manage_first_run) do
        {:ok, %{gym: gym}} -> state(gym, fetch(gym.id, user_id))
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  An explicit transition (`attrs` is the request body and must be empty):

    * `:start` - not started -> in progress; repeated while in progress, the
      same state (the first `started_at` is kept);
    * `:complete` - not started or in progress -> `completed`; repeated, the
      same state;
    * `:dismiss` - not started or in progress -> `dismissed`; repeated, the
      same state.

  Any other transition is a conflict naming the kept outcome
  (`first_run: completed | dismissed`) and changes nothing; so is any
  transition on a draft (`setup_status: draft`).
  """
  @spec transition(User.t(), term(), action(), map()) :: {:ok, state()} | {:error, error()}
  def transition(%User{id: user_id} = user, gym_id, action, attrs)
      when is_binary(user_id) and action in [:start, :complete, :dismiss] and is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, %{gym: gym}} <- Access.authorize_shared(user, gym_id, :manage_first_run),
           :ok <- no_fields(attrs),
           :ok <- completed(gym),
           {:ok, row} <- apply_action(gym.id, user_id, action, now()) do
        state(gym, row)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> tap(&emit(action, &1))
  end

  @doc "The checklist of a gym, derived from its persisted facts."
  @spec checklist(Gym.t()) :: [item()]
  def checklist(%Gym{} = gym), do: Enum.map(@checklist, &%{key: &1, status: item(&1, gym)})

  # Creating the gym (OG1 + OG2) is done when its setup is completed (SF-85);
  # the owner of a draft can still finish it.
  defp item(:create_gym, %Gym{setup_status: :completed}), do: :completed
  defp item(:create_gym, %Gym{setup_status: :draft}), do: :available
  # "Invite staff" is done once a staff invitation was accepted (SF-82 03 §3,
  # C7; ADR 0026 SF-90 amendment): a person joined the team. Sending one is
  # not enough, and a later removal does not undo it (the gym's history).
  # Only a completed gym invites, so a draft has nothing to offer yet.
  defp item(:invite_staff, %Gym{setup_status: :completed, id: gym_id}) do
    accepted? =
      Repo.exists?(
        from(i in StaffInvitation, where: i.gym_id == ^gym_id and i.status == :accepted),
        log: false
      )

    if accepted?, do: :completed, else: :available
  end

  # No class, member or check-in domain exists yet (and a draft invites no
  # staff yet).
  defp item(_future, %Gym{}), do: :coming_later

  # -- Transitions ---------------------------------------------------------------

  defp apply_action(gym_id, user_id, action, now) do
    case lock(gym_id, user_id) do
      nil -> insert(gym_id, user_id, action, now)
      row -> decide(row, action, now)
    end
  end

  # The first action creates the row. A concurrent first action that commits
  # first makes this insert a no-op; the row is then read and decided like
  # any existing one (under its lock), so both requests agree.
  defp insert(gym_id, user_id, action, now) do
    fields =
      case action do
        :start -> [started_at: now]
        :complete -> [started_at: now, completed_at: now]
        :dismiss -> [dismissed_at: now]
      end

    row =
      Map.merge(
        %{id: Ecto.UUID.generate(), gym_id: gym_id, user_id: user_id, inserted_at: now},
        Map.new([{:updated_at, now} | fields])
      )

    case Repo.insert_all(GymFirstRun, [row],
           on_conflict: :nothing,
           conflict_target: [:gym_id, :user_id],
           returning: true
         ) do
      {1, [inserted]} ->
        if action != :start, do: audit!(inserted, action, now)
        {:ok, inserted}

      {0, []} ->
        decide(lock(gym_id, user_id), action, now)
    end
  end

  defp decide(%GymFirstRun{completed_at: %DateTime{}} = row, :complete, _now), do: {:ok, row}
  defp decide(%GymFirstRun{dismissed_at: %DateTime{}} = row, :dismiss, _now), do: {:ok, row}

  defp decide(%GymFirstRun{completed_at: %DateTime{}}, _action, _now),
    do: {:error, {:conflict, %{first_run: "completed"}}}

  defp decide(%GymFirstRun{dismissed_at: %DateTime{}}, _action, _now),
    do: {:error, {:conflict, %{first_run: "dismissed"}}}

  defp decide(%GymFirstRun{} = row, :start, _now), do: {:ok, row}

  defp decide(%GymFirstRun{} = row, action, now) do
    field = if action == :complete, do: :completed_at, else: :dismissed_at
    # Never before the start, whatever the clocks of two app nodes say.
    at = if row.started_at, do: Enum.max([now, row.started_at], DateTime), else: now
    row = row |> Changeset.change([{field, at}]) |> Repo.update!()
    audit!(row, action, at)
    {:ok, row}
  end

  defp audit!(%GymFirstRun{gym_id: gym_id, user_id: user_id}, action, now) do
    type = if action == :complete, do: :first_run_completed, else: :first_run_dismissed
    Audit.record!(%{gym_id: gym_id, actor_user_id: user_id, event_type: type}, now)
  end

  defp lock(gym_id, user_id) do
    Repo.one(
      from(r in GymFirstRun,
        where: r.gym_id == ^gym_id and r.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp fetch(gym_id, user_id),
    do: Repo.one(from(r in GymFirstRun, where: r.gym_id == ^gym_id and r.user_id == ^user_id))

  # Transitions take no input: the gym is the path's, the user the
  # session's. Any field (a forged `user_id`, a checklist flag) is refused.
  defp no_fields(attrs) when map_size(attrs) == 0, do: :ok

  defp no_fields(attrs) do
    changeset =
      attrs
      |> Map.keys()
      |> Enum.sort_by(&to_string/1)
      |> Enum.reduce(Changeset.change({%{}, %{}}), fn key, acc ->
        %{acc | errors: [{key, {"is not accepted", []}} | acc.errors], valid?: false}
      end)

    {:error, changeset}
  end

  defp completed(%Gym{setup_status: :completed}), do: :ok
  defp completed(%Gym{}), do: {:error, {:conflict, %{setup_status: "draft"}}}

  # -- Views ---------------------------------------------------------------------

  defp state(%Gym{} = gym, row) do
    %{
      gym_id: gym.id,
      status: status(gym, row),
      started_at: row && row.started_at,
      completed_at: row && row.completed_at,
      dismissed_at: row && row.dismissed_at,
      checklist: checklist(gym)
    }
  end

  defp status(%Gym{setup_status: :draft}, _row), do: :unavailable
  defp status(_gym, nil), do: :not_started
  defp status(_gym, %GymFirstRun{completed_at: %DateTime{}}), do: :completed
  defp status(_gym, %GymFirstRun{dismissed_at: %DateTime{}}), do: :dismissed
  defp status(_gym, %GymFirstRun{}), do: :in_progress

  defp now, do: DateTime.utc_now()

  # Outcomes only: never an id or a name.
  defp emit(action, result) do
    outcome =
      case result do
        {:ok, _} -> :ok
        {:error, %Changeset{}} -> :invalid
        {:error, {:conflict, _}} -> :conflict
        {:error, reason} -> reason
      end

    :telemetry.execute([:simple_fit, :gyms, :first_run, action], %{count: 1}, %{outcome: outcome})
  end
end
