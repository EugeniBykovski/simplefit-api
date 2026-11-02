defmodule SimpleFit.Gyms.Schedule do
  @moduledoc """
  What the timetable modules (`Venues`, `ClassTemplates`, `Timetable`;
  SF-97) share: the write transaction, parameter checks, the instructor
  projection and the telemetry. Internal to `SimpleFit.Gyms`.

  ## Writes

  Every timetable write runs in one transaction that holds the caller's
  session (`FOR SHARE`: a sign-out or revocation commits before or after,
  never during), then locks the gym row and the actor's active staff
  membership (`Access.authorize_locked/3`, the SF-83 order every staff
  change uses). So all timetable writes of one gym, and its staff
  revocations and role changes, serialize; writes of different gyms do not
  wait on each other (an instructor shared by two gyms is guarded by the
  database's exclusion constraint instead). The gym must be completed, and
  timetable writes count against 120 per 10 minutes per user.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.{Accounts, RateLimit, Repo}
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Gyms.{Access, Gym, Members, MemberSecrets, StaffMembership}

  @unlogged [log: false]

  # Who may instruct a class (SF-82 02: owner, manager and coach run
  # classes; front desk does not). The database enforces the same list.
  @instructor_roles [:owner, :manager, :coach]

  @type error ::
          :not_found
          | :forbidden
          | :session_revoked
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | Changeset.t()

  @doc "The staff roles that may instruct a class."
  @spec instructor_roles() :: [atom()]
  def instructor_roles, do: @instructor_roles

  @doc """
  Runs `fun.(access)` in a timetable write transaction (see the moduledoc):
  `fun` returns `{:ok, value}` or `{:error, reason}` (rolled back).
  """
  @spec write(User.t(), Session.t(), term(), atom(), (Access.t() ->
                                                        {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, error()}
  def write(%User{} = user, %Session{} = session, gym_id, permission, fun),
    do: retrying(fn -> transaction(user, session, gym_id, permission, fun) end, 3)

  # Two transactions inserting overlapping rows at the same time (two gyms
  # assigning one instructor) each wait for the other in the exclusion
  # constraint's check, and PostgreSQL aborts one (`deadlock_detected`).
  # Nothing of it committed, so it runs again and then meets the committed
  # row as an ordinary conflict.
  defp retrying(run, attempts) do
    run.()
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :deadlock_detected and attempts > 1,
        do: retrying(run, attempts - 1),
        else: reraise(error, __STACKTRACE__)
  end

  defp transaction(user, session, gym_id, permission, fun) do
    Repo.transaction(
      fn ->
        with :ok <- Members.held(Accounts.hold_active_session(user, session)),
             {:ok, access} <- Access.authorize_locked(user, gym_id, permission),
             :ok <- completed(access.gym),
             :ok <- limit(user),
             {:ok, value} <- fun.(access) do
          value
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
  end

  @doc "Read access: any active staff member of the gym (`view_workspace`)."
  @spec read(User.t(), term()) :: {:ok, Access.t()} | {:error, :not_found | :forbidden}
  def read(%User{} = user, gym_id), do: Access.authorize(user, gym_id, :view_workspace)

  defp completed(%Gym{setup_status: :completed}), do: :ok
  defp completed(%Gym{}), do: {:error, {:conflict, %{setup_status: "draft"}}}

  defp limit(%User{id: user_id}),
    do:
      RateLimit.hit([
        {"gym_schedule_admin_user", MemberSecrets.rate_limit_key("user", user_id), 120, 600}
      ])

  @doc """
  The optimistic revision check: `expected_revision` must be given (`422`)
  and equal the row's (`409 revision: stale`, with the current one).
  """
  @spec revision(map(), pos_integer()) :: :ok | {:error, term()}
  def revision(attrs, current) do
    case Map.fetch(attrs, "expected_revision") do
      {:ok, ^current} ->
        :ok

      {:ok, value} when is_integer(value) and value >= 1 ->
        {:error, {:conflict, %{revision: "stale", current_revision: current}}}

      {:ok, _other} ->
        {:error, field_error(:expected_revision, "must be a positive integer", :cast)}

      :error ->
        {:error, field_error(:expected_revision, "can't be blank", :required)}
    end
  end

  @doc "A changeset carrying one field error (for the `422` envelope)."
  @spec field_error(atom(), String.t(), atom()) :: Changeset.t()
  def field_error(field, message, validation) do
    {%{}, %{field => :string}}
    |> Changeset.change()
    |> Changeset.add_error(field, message, validation: validation)
  end

  @doc "Rejects any key outside `allowed` (no tenant, status or id overrides)."
  @spec reject_unknown(Changeset.t(), map(), [String.t()]) :: Changeset.t()
  def reject_unknown(changeset, attrs, allowed),
    do: Members.reject_unknown_fields(changeset, attrs, allowed)

  @doc "The changeset's data, or `{:error, changeset}`."
  @spec apply(Changeset.t()) :: {:ok, map()} | {:error, Changeset.t()}
  def apply(%Changeset{valid?: true} = changeset), do: {:ok, Changeset.apply_changes(changeset)}
  def apply(%Changeset{} = changeset), do: {:error, changeset}

  @doc """
  An eligible instructor of the gym (`nil` stays `nil`): an active owner,
  manager or coach membership, locked `FOR SHARE` (a revocation, which
  locks the gym first, cannot interleave). Otherwise a `422` on `field`.
  """
  @spec instructor(Ecto.UUID.t(), term(), atom()) ::
          {:ok, StaffMembership.t() | nil} | {:error, Changeset.t()}
  def instructor(_gym_id, nil, _field), do: {:ok, nil}

  def instructor(gym_id, membership_id, field) do
    with {:ok, id} <- Access.cast_id(membership_id),
         %StaffMembership{} = membership <-
           Repo.one(
             from(m in StaffMembership,
               where:
                 m.id == ^id and m.gym_id == ^gym_id and m.status == :active and
                   m.role in ^@instructor_roles,
               lock: "FOR SHARE"
             ),
             @unlogged
           ) do
      {:ok, membership}
    else
      _ -> {:error, field_error(field, "is not an instructor of this gym", :inclusion)}
    end
  end

  @doc """
  The instructor projection for `membership_ids`: `%{id => %{staff_membership_id,
  name}}` with the short name ("Tomasz Z."), never an email or profile.
  """
  @spec instructors([Ecto.UUID.t() | nil]) :: %{Ecto.UUID.t() => map()}
  def instructors(membership_ids) do
    ids = membership_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    rows =
      Repo.all(
        from(m in StaffMembership, where: m.id in ^ids, select: {m.id, m.user_id}),
        @unlogged
      )

    names = Accounts.short_names(rows |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1))

    Map.new(rows, fn {id, user_id} ->
      {id, %{staff_membership_id: id, name: get_in(names, [user_id, :short_name])}}
    end)
  end

  @doc "Telemetry for a timetable operation: outcomes only, never an id, title or time."
  @spec emit(atom(), {:ok, term()} | {:error, term()}) :: :ok
  def emit(event, result) do
    outcome =
      case result do
        {:ok, {_view, outcome}} when outcome in [:created, :existing] -> outcome
        {:ok, _} -> :ok
        {:error, %Changeset{}} -> :validation_error
        {:error, {:conflict, _}} -> :conflict
        {:error, {:rate_limited, _}} -> :rate_limited
        {:error, reason} when is_atom(reason) -> reason
      end

    :telemetry.execute([:simple_fit, :gyms, :timetable, event], %{count: 1}, %{outcome: outcome})
  end
end
