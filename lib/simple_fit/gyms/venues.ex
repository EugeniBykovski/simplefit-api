defmodule SimpleFit.Gyms.Venues do
  @moduledoc """
  Gym venues (SF-97): the training areas classes take place in. Internal
  to `SimpleFit.Gyms`; see `SimpleFit.Gyms.Venue` for the model.

  Every active staff member reads them; owners and managers
  (`manage_timetable`) create, update and deactivate them. A venue is at an
  active location of its own gym; its zone is an IANA id and never changes
  (its classes were scheduled in it); its capacity, when set, caps every
  class held there and may not drop below a class still to come.
  Deactivating refuses while classes are still to come in it (move or
  cancel them first), so no scheduled class is left in an inactive venue.
  Nothing is deleted.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.{Clock, Repo, Scheduling}
  alias SimpleFit.Gyms.{Access, Audit, ClassOccurrence, GymLocation, Paging, Schedule, Venue}

  @unlogged [log: false]
  @control ~r/[\p{Cc}\p{Cf}]/u

  @doc "The gym's venues, by name (params: `status` `active` (default) or `inactive`, `limit`, `cursor`)."
  @spec list(User.t(), term(), map()) :: {:ok, map()} | {:error, Schedule.error()}
  def list(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym}} <- Schedule.read(user, gym_id),
         {:ok, %{limit: limit, status: status}} <-
           Paging.params(Map.delete(params, "cursor"), [:active, :inactive], :active) do
      venues =
        Repo.all(
          from(v in Venue,
            where: v.gym_id == ^gym.id and v.status == ^status,
            order_by: [asc: fragment("lower(?)", v.name), asc: v.id],
            limit: ^limit
          ),
          @unlogged
        )

      {:ok, %{entries: Enum.map(venues, &view/1)}}
    end
  end

  @doc "One venue of the gym."
  @spec get(User.t(), term(), term()) :: {:ok, map()} | {:error, Schedule.error()}
  def get(%User{} = user, gym_id, venue_id) do
    with {:ok, %{gym: gym}} <- Schedule.read(user, gym_id),
         %Venue{} = venue <- fetch(gym.id, venue_id, false) do
      {:ok, view(venue)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a venue (`attrs`: `client_request_id`, `gym_location_id`, `name`,
  `time_zone`, optional `description` and `capacity`). The same
  `client_request_id` again returns the venue it created (`:existing`).
  """
  @spec create(User.t(), Session.t(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, Schedule.error()}
  def create(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    Schedule.write(user, session, gym_id, :manage_timetable, &create_in(&1.gym, user, attrs))
    |> tap(&Schedule.emit(:venue_created, &1))
  end

  defp create_in(gym, user, attrs) do
    with {:ok, params} <- create_params(attrs) do
      case Repo.get_by(
             Venue,
             [gym_id: gym.id, client_request_id: params.client_request_id],
             @unlogged
           ) do
        %Venue{} = existing -> {:ok, {view(existing), :existing}}
        nil -> insert(gym.id, user, params)
      end
    end
  end

  defp insert(gym_id, user, params) do
    with :ok <- location(gym_id, params.gym_location_id),
         :ok <- unique_name(gym_id, params.name, nil) do
      now = DateTime.utc_now()

      venue =
        Repo.insert!(
          %Venue{
            gym_id: gym_id,
            gym_location_id: params.gym_location_id,
            name: params.name,
            description: params.description,
            capacity: params.capacity,
            time_zone: params.time_zone,
            client_request_id: params.client_request_id,
            created_by_user_id: user.id
          },
          @unlogged
        )

      audit!(gym_id, user.id, :venue_created, venue, now)
      {:ok, {view(venue), :created}}
    end
  end

  @doc """
  Updates a venue (`attrs`: `expected_revision` and any of `name`,
  `description`, `capacity`, `gym_location_id`; `null` clears the optional
  ones). Its zone never changes.
  """
  @spec update(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, Schedule.error()}
  def update(%User{} = user, %Session{} = session, gym_id, venue_id, attrs) when is_map(attrs) do
    Schedule.write(user, session, gym_id, :manage_timetable, fn %{gym: gym} ->
      with %Venue{} = venue <- fetch(gym.id, venue_id, true) || {:error, :not_found},
           :ok <- active(venue),
           :ok <- Schedule.revision(attrs, venue.revision),
           {:ok, changes} <- update_params(attrs, venue),
           :ok <- maybe_location(gym.id, changes),
           :ok <- maybe_name(gym.id, changes, venue),
           :ok <- capacity_fits(venue, changes) do
        now = DateTime.utc_now()

        updated =
          venue
          |> Changeset.change(
            Map.merge(changes, %{revision: venue.revision + 1, updated_at: now})
          )
          |> Repo.update!(@unlogged)

        audit!(gym.id, user.id, :venue_updated, updated, now)
        {:ok, view(updated)}
      end
    end)
    |> tap(&Schedule.emit(:venue_updated, &1))
  end

  @doc """
  Deactivates a venue (`attrs`: `expected_revision`). Refused (`409 venue:
  has_upcoming_classes`) while scheduled classes are still to come in it.
  Deactivating an inactive venue again returns it unchanged.
  """
  @spec deactivate(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, Schedule.error()}
  def deactivate(%User{} = user, %Session{} = session, gym_id, venue_id, attrs)
      when is_map(attrs) do
    Schedule.write(
      user,
      session,
      gym_id,
      :manage_timetable,
      &deactivate_in(&1.gym, user, fetch(&1.gym.id, venue_id, true), attrs)
    )
    |> tap(&Schedule.emit(:venue_deactivated, &1))
  end

  defp deactivate_in(_gym, _user, nil, _attrs), do: {:error, :not_found}

  defp deactivate_in(_gym, _user, %Venue{status: :inactive} = venue, _attrs),
    do: {:ok, view(venue)}

  defp deactivate_in(gym, user, %Venue{} = venue, attrs) do
    with :ok <- Schedule.revision(attrs, venue.revision),
         :ok <- no_upcoming(venue) do
      now = DateTime.utc_now()

      updated =
        venue
        |> Changeset.change(
          status: :inactive,
          deactivated_at: now,
          revision: venue.revision + 1,
          updated_at: now
        )
        |> Repo.update!(@unlogged)

      audit!(gym.id, user.id, :venue_deactivated, updated, now)
      {:ok, view(updated)}
    end
  end

  @doc false
  # The venue of `gym_id` by id (`lock?`: `FOR UPDATE`), or `nil`.
  @spec fetch(Ecto.UUID.t(), term(), boolean()) :: Venue.t() | nil
  def fetch(gym_id, venue_id, lock?) do
    case Access.cast_id(venue_id) do
      {:ok, id} ->
        query = from(v in Venue, where: v.id == ^id and v.gym_id == ^gym_id)
        query = if lock?, do: from(v in query, lock: "FOR UPDATE"), else: query
        Repo.one(query, @unlogged)

      :error ->
        nil
    end
  end

  defp active(%Venue{status: :active}), do: :ok
  defp active(%Venue{}), do: {:error, {:conflict, %{venue: "inactive"}}}

  defp no_upcoming(%Venue{id: id}) do
    now = Clock.utc_now()

    upcoming =
      Repo.aggregate(
        from(o in ClassOccurrence,
          where: o.venue_id == ^id and o.status == :scheduled and o.starts_at > ^now
        ),
        :count,
        @unlogged
      )

    if upcoming == 0,
      do: :ok,
      else: {:error, {:conflict, %{venue: "has_upcoming_classes", upcoming_classes: upcoming}}}
  end

  defp capacity_fits(%Venue{} = venue, %{capacity: capacity}) when is_integer(capacity) do
    now = Clock.utc_now()

    over =
      Repo.aggregate(
        from(o in ClassOccurrence,
          where:
            o.venue_id == ^venue.id and o.status == :scheduled and o.starts_at > ^now and
              o.capacity > ^capacity
        ),
        :count,
        @unlogged
      )

    if over == 0,
      do: :ok,
      else:
        {:error, {:conflict, %{venue: "capacity_below_upcoming_class", upcoming_classes: over}}}
  end

  defp capacity_fits(_venue, _changes), do: :ok

  defp location(gym_id, location_id) do
    exists? =
      Repo.exists?(
        from(l in GymLocation,
          where: l.id == ^location_id and l.gym_id == ^gym_id and is_nil(l.archived_at)
        ),
        @unlogged
      )

    if exists?,
      do: :ok,
      else:
        {:error,
         Schedule.field_error(:gym_location_id, "is not a location of this gym", :inclusion)}
  end

  defp maybe_location(gym_id, %{gym_location_id: id}), do: location(gym_id, id)
  defp maybe_location(_gym_id, _changes), do: :ok

  defp maybe_name(gym_id, %{name: name}, venue), do: unique_name(gym_id, name, venue.id)
  defp maybe_name(_gym_id, _changes, _venue), do: :ok

  defp unique_name(gym_id, name, except_id) do
    query =
      from(v in Venue,
        where:
          v.gym_id == ^gym_id and v.status == :active and
            fragment("lower(?)", v.name) == ^String.downcase(name)
      )

    query = if except_id, do: from(v in query, where: v.id != ^except_id), else: query

    if Repo.exists?(query, @unlogged),
      do:
        {:error,
         Schedule.field_error(:name, "is already the name of a venue here", :unsafe_unique)},
      else: :ok
  end

  ## Params

  @create ~w(client_request_id gym_location_id name description capacity time_zone)
  @update ~w(expected_revision gym_location_id name description capacity)

  defp create_params(attrs) do
    {%{}, types()}
    |> Changeset.cast(attrs, Map.keys(types()) -- [:expected_revision])
    |> Changeset.validate_required([:client_request_id, :gym_location_id, :name, :time_zone])
    |> Schedule.reject_unknown(attrs, @create)
    |> validate()
    |> validate_zone()
    |> Schedule.apply()
    |> case do
      {:ok, params} -> {:ok, Map.merge(%{description: nil, capacity: nil}, params)}
      error -> error
    end
  end

  # Cast against the current values, so `null` clears an optional field and
  # an unchanged value is no change.
  defp update_params(attrs, venue) do
    current = Map.take(venue, [:gym_location_id, :name, :description, :capacity])

    changeset =
      {current, types()}
      |> Changeset.cast(attrs, [:gym_location_id, :name, :description, :capacity])
      |> Schedule.reject_unknown(attrs, @update)
      |> validate()

    for field <- [:gym_location_id, :name],
        Map.has_key?(attrs, to_string(field)) and is_nil(attrs[to_string(field)]),
        reduce: changeset do
      acc -> Changeset.add_error(acc, field, "can't be blank", validation: :required)
    end
    |> case do
      %Changeset{valid?: true} = valid -> {:ok, valid.changes}
      invalid -> {:error, invalid}
    end
  end

  defp types do
    %{
      client_request_id: Ecto.UUID,
      gym_location_id: Ecto.UUID,
      name: :string,
      description: :string,
      capacity: :integer,
      time_zone: :string,
      expected_revision: :integer
    }
  end

  defp validate(changeset) do
    changeset
    |> Changeset.update_change(:name, &String.trim/1)
    |> Changeset.update_change(:description, &blank_to_nil/1)
    |> Changeset.validate_length(:name, min: 1, max: 80)
    |> Changeset.validate_format(:name, ~r/\A[^\p{Cc}\p{Cf}]*\z/u)
    |> Changeset.validate_length(:description, max: 500)
    |> Changeset.validate_change(:description, &no_control/2)
    |> Changeset.validate_number(:capacity,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 500
    )
  end

  defp validate_zone(changeset) do
    Changeset.validate_change(changeset, :time_zone, fn :time_zone, zone ->
      if Scheduling.valid_time_zone?(zone),
        do: [],
        else: [time_zone: {"is not a known IANA time zone", [validation: :inclusion]}]
    end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp no_control(field, value) do
    if is_binary(value) and Regex.match?(@control, String.replace(value, ~r/[\n\t]/, "")),
      do: [{field, {"has invalid characters", [validation: :format]}}],
      else: []
  end

  ## Views

  @doc false
  @spec view(Venue.t()) :: map()
  def view(%Venue{} = venue) do
    %{
      venue_id: venue.id,
      gym_id: venue.gym_id,
      gym_location_id: venue.gym_location_id,
      name: venue.name,
      description: venue.description,
      capacity: venue.capacity,
      time_zone: venue.time_zone,
      status: venue.status,
      revision: venue.revision,
      created_at: venue.inserted_at,
      updated_at: venue.updated_at
    }
  end

  defp audit!(gym_id, actor_id, event, venue, now),
    do:
      Audit.record!(
        %{gym_id: gym_id, actor_user_id: actor_id, event_type: event, venue_id: venue.id},
        now
      )
end
