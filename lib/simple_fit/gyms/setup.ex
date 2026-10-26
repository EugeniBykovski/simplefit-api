defmodule SimpleFit.Gyms.Setup do
  @moduledoc """
  Gym owner registration and setup (SF-85; ADR 0026 D-G05, D-G20, D-G21).
  Internal to `SimpleFit.Gyms`.

  A gym is created as a `draft` by `SimpleFit.Gyms.Creation` (the only
  create). Setup then saves, in any order and as often as needed:

    * the profile (`name`, `gym_type`, optional `phone`, `website`) and text
      branding (`tagline`, `accent_color`) with a partial update;
    * the primary location (address only), set or replaced as a whole.

  `complete/2` re-validates the persisted state and moves the gym to
  `completed` once (final; the database also refuses completion without an
  active primary location). `discard/2` deletes a draft and everything that
  belongs to it. Completion requires nothing commercial: no plan, payment,
  verification, publication, staff, members or timetable (D-G09-D-G11).

  ## Authorization and locks

  Every write runs in one transaction that locks the gym row, then the
  actor's membership (`Access.authorize_locked/3`), then the primary
  location: the same order as ownership transfer, revocation and the entry
  context choice, so they serialize without deadlocks. Permissions come from
  the fixed matrix: profile and location edits `edit_gym` /
  `manage_locations` (owner, manager), completion `complete_setup` and
  discard `discard_draft` (owner only). A draft's owner needs no
  `GYM_WORKSPACE` capability (SF-84): access is the membership.

  ## Concurrency

  Each setup change bumps the gym's `revision`. A write may carry
  `expected_revision`; when it is stale the write is refused with `409
  conflict` (`revision: stale`) and changes nothing. Without it, a partial
  update changes only the fields it names, so concurrent edits of different
  fields never overwrite each other.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{Access, Audit, Gym, GymLocation, StaffMembership}
  alias SimpleFit.Repo

  @update_keys Enum.map(Gym.setup_fields(), &Atom.to_string/1) ++ ["expected_revision"]
  @location_keys Enum.map(GymLocation.fields(), &Atom.to_string/1) ++ ["expected_revision"]

  @type state :: %{
          gym: Gym.t(),
          primary_location: GymLocation.t() | nil,
          membership: StaffMembership.t()
        }
  @type error :: :not_found | :forbidden | {:conflict, map()} | Changeset.t()

  @doc "The setup state of a gym, for its active staff."
  @spec get(User.t(), term()) :: {:ok, state()} | {:error, :not_found}
  def get(%User{} = user, gym_id) do
    with {:ok, %{gym: gym, membership: membership}} <-
           Access.authorize(user, gym_id, :view_workspace) do
      {:ok, %{gym: gym, membership: membership, primary_location: primary_location(gym.id)}}
    end
  end

  @doc """
  A partial setup update (`attrs`, string keys: any of `Gym.setup_fields/0`
  and optional `expected_revision`; nothing else). An omitted field is
  unchanged; `null` or a blank string clears an optional field; `name` and
  `gym_type` cannot be cleared. An update that changes nothing returns the
  current state without bumping the revision.
  """
  @spec update(User.t(), term(), map()) :: {:ok, state()} | {:error, error()}
  def update(%User{} = user, gym_id, attrs) when is_map(attrs) do
    transaction(:updated, fn ->
      with {:ok, %{gym: gym, membership: membership}} <-
             Access.authorize_locked(user, gym_id, :edit_gym),
           {:ok, expected} <- request(attrs, @update_keys),
           :ok <- fresh(gym, expected),
           {:ok, gym} <- apply_update(gym, attrs) do
        %{gym: gym, membership: membership, primary_location: lock_primary_location(gym.id)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Sets the primary location (`attrs`, string keys: `country_code`, `city`,
  `address_line`, optional `entrance_note`, `name`, and optional
  `expected_revision`). The first call creates it; later calls replace its
  fields in place (one row, never a second primary). An identical address
  changes nothing.
  """
  @spec put_primary_location(User.t(), term(), map()) :: {:ok, state()} | {:error, error()}
  def put_primary_location(%User{} = user, gym_id, attrs) when is_map(attrs) do
    transaction(:primary_location_set, fn ->
      with {:ok, %{gym: gym, membership: membership}} <-
             Access.authorize_locked(user, gym_id, :manage_locations),
           {:ok, expected} <- request(attrs, @location_keys),
           :ok <- fresh(gym, expected),
           {:ok, gym, location} <- apply_location(gym, attrs, user.id) do
        %{gym: gym, membership: membership, primary_location: location}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Completes the setup of a draft (owner only), re-validating the persisted
  state: a valid name and type, an active primary location with a complete
  address and exactly one active owner. Missing requirements are a
  validation error naming each one. Completing a completed gym returns it
  unchanged (`:already_completed`, no second audit event).
  """
  @spec complete(User.t(), term()) ::
          {:ok, state(), :completed | :already_completed} | {:error, error()}
  def complete(%User{} = user, gym_id) do
    Repo.transaction(fn ->
      case Access.authorize_locked(user, gym_id, :complete_setup) do
        {:ok, %{gym: gym, membership: membership}} ->
          finish(gym, membership, lock_primary_location(gym.id), user.id)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {state, outcome}} ->
        emit(:completed, outcome)
        {:ok, state, outcome}

      {:error, reason} ->
        emit(:completed, tag(reason))
        {:error, reason}
    end
  end

  @doc """
  Discards a draft (owner only): the gym, its owner membership, its
  locations and any entry choice naming it are deleted in one transaction,
  and a `draft_discarded` audit event is kept (audit events have no foreign
  keys). A completed gym is never discarded (`409 conflict`,
  `setup_status: completed`). Discarding again answers `not_found`.
  """
  @spec discard(User.t(), term()) :: :ok | {:error, :not_found | :forbidden | {:conflict, map()}}
  def discard(%User{} = user, gym_id) do
    Repo.transaction(fn ->
      with {:ok, %{gym: gym}} <- Access.authorize_locked(user, gym_id, :discard_draft),
           :ok <- still_draft(gym) do
        Audit.record!(
          %{gym_id: gym.id, actor_user_id: user.id, event_type: :draft_discarded},
          DateTime.utc_now()
        )

        {:ok, _deleted} = Repo.delete(gym, log: false)
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} ->
        emit(:discarded, :ok)
        :ok

      {:error, reason} ->
        emit(:discarded, tag(reason))
        {:error, reason}
    end
  end

  @doc """
  The requirements a draft still misses for completion, by field
  (`[:primary_location]`, `[:name]`, ...); empty when it can complete.
  """
  @spec missing_requirements(Gym.t(), GymLocation.t() | nil) :: [atom()]
  def missing_requirements(%Gym{} = gym, location) do
    profile =
      gym
      |> Gym.setup_changeset(%{})
      |> Changeset.validate_required([:name, :gym_type])
      |> Map.fetch!(:errors)
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.filter(&(&1 in [:name, :gym_type]))

    location_missing =
      case location do
        %GymLocation{} = location ->
          if address_complete?(location), do: [], else: [:primary_location]

        nil ->
          [:primary_location]
      end

    profile ++ location_missing
  end

  # -- Update --------------------------------------------------------------------

  defp apply_update(gym, attrs) do
    changeset = Gym.setup_changeset(gym, Map.drop(attrs, ["expected_revision"]))

    cond do
      not changeset.valid? -> {:error, changeset}
      changeset.changes == %{} -> {:ok, gym}
      true -> Repo.update(changeset, log: false)
    end
  end

  # -- Location ------------------------------------------------------------------

  defp apply_location(gym, attrs, actor_id) do
    current = lock_primary_location(gym.id)
    base = current || %GymLocation{gym_id: gym.id, is_primary: true}
    changeset = GymLocation.address_changeset(base, Map.drop(attrs, ["expected_revision"]))

    cond do
      not changeset.valid? ->
        {:error, changeset}

      current != nil and changeset.changes == %{} ->
        {:ok, gym, current}

      true ->
        {:ok, location} = Repo.insert_or_update(changeset, log: false)
        gym = gym |> Gym.touch_changeset() |> Repo.update!(log: false)

        Audit.record!(
          %{gym_id: gym.id, actor_user_id: actor_id, event_type: :primary_location_set},
          DateTime.utc_now()
        )

        {:ok, gym, location}
    end
  end

  defp address_complete?(location),
    do: location |> GymLocation.address_changeset(%{}) |> Map.fetch!(:valid?)

  # -- Completion ------------------------------------------------------------------

  defp finish(%Gym{setup_status: :completed} = gym, membership, location, _actor_id),
    do: {%{gym: gym, membership: membership, primary_location: location}, :already_completed}

  defp finish(gym, membership, location, actor_id) do
    with [] <- missing_requirements(gym, location),
         1 <- active_owners(gym.id) do
      gym =
        gym
        |> Changeset.change(setup_status: :completed, revision: gym.revision + 1)
        |> Repo.update!(log: false)

      Audit.record!(
        %{gym_id: gym.id, actor_user_id: actor_id, event_type: :setup_completed},
        DateTime.utc_now()
      )

      {%{gym: gym, membership: membership, primary_location: location}, :completed}
    else
      missing when is_list(missing) -> Repo.rollback(incomplete(missing))
      _owners -> Repo.rollback({:conflict, %{owner: "not_exactly_one"}})
    end
  end

  # Each missing requirement as a `required` validation error under its name.
  defp incomplete(missing) do
    Enum.reduce(missing, Changeset.change({%{}, %{}}), fn field, acc ->
      Changeset.add_error(acc, field, "is required to complete setup", validation: :required)
    end)
  end

  defp active_owners(gym_id) do
    Repo.aggregate(
      from(m in StaffMembership,
        where: m.gym_id == ^gym_id and m.role == :owner and m.status == :active
      ),
      :count
    )
  end

  defp still_draft(%Gym{setup_status: :draft}), do: :ok
  defp still_draft(%Gym{}), do: {:error, {:conflict, %{setup_status: "completed"}}}

  # -- Shared ------------------------------------------------------------------------

  # Every rollback reason is an `error()` (see the callers' `with ... else`).
  @spec transaction(atom(), (-> state())) :: {:ok, state()} | {:error, error()}
  defp transaction(event, fun) do
    result =
      case Repo.transaction(fun) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:error, as_error(reason)}
      end

    emit(event, tag(result))
    result
  end

  # Only the documented reasons leave a setup write; anything else is a bug.
  defp as_error(%Changeset{} = changeset), do: changeset
  defp as_error({:conflict, details}) when is_map(details), do: {:conflict, details}
  defp as_error(reason) when reason in [:not_found, :forbidden], do: reason

  defp request(attrs, allowed) do
    unknown = attrs |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort_by(&to_string/1)

    changeset =
      {%{}, %{expected_revision: :integer}}
      |> Changeset.cast(attrs, [:expected_revision])
      |> Changeset.validate_number(:expected_revision, greater_than: 0)

    changeset =
      Enum.reduce(unknown, changeset, fn key, acc ->
        %{acc | errors: [{key, {"is not a setup field", []}} | acc.errors], valid?: false}
      end)

    if changeset.valid?,
      do: {:ok, Changeset.get_field(changeset, :expected_revision)},
      else: {:error, changeset}
  end

  defp fresh(_gym, nil), do: :ok
  defp fresh(%Gym{revision: revision}, revision), do: :ok
  defp fresh(%Gym{}, _stale), do: {:error, {:conflict, %{revision: "stale"}}}

  defp primary_location(gym_id),
    do: Repo.one(primary_query(gym_id), log: false)

  defp lock_primary_location(gym_id),
    do: Repo.one(from(l in primary_query(gym_id), lock: "FOR UPDATE"), log: false)

  defp primary_query(gym_id),
    do:
      from(l in GymLocation,
        where: l.gym_id == ^gym_id and l.is_primary and is_nil(l.archived_at)
      )

  defp tag({:ok, _}), do: :ok
  defp tag({:error, reason}), do: tag(reason)
  defp tag(%Changeset{}), do: :invalid
  defp tag({:conflict, _details}), do: :conflict
  defp tag(reason) when is_atom(reason), do: reason

  # Outcomes only: never a name, address or id.
  defp emit(event, outcome),
    do: :telemetry.execute([:simple_fit, :gyms, :setup, event], %{count: 1}, %{outcome: outcome})
end
