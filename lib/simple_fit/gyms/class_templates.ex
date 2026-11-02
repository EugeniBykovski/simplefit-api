defmodule SimpleFit.Gyms.ClassTemplates do
  @moduledoc """
  Gym class templates (SF-97): reusable class definitions. Internal to
  `SimpleFit.Gyms`; see `SimpleFit.Gyms.ClassTemplate` for the model.

  Every active staff member reads them; owners and managers
  (`manage_timetable`) create, update and archive them. A template's
  defaults (duration, capacity, venue, instructor) are only what new series
  and one-time classes start from: editing a template never changes a
  class already scheduled (each keeps the title, duration, capacity, venue
  and instructor it was scheduled with). A default venue must be an active
  venue of the gym whose capacity holds the default capacity; a default
  instructor an eligible instructor of the gym. Archiving stops new classes
  from the template; its scheduled classes stay as they are.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Gyms.{Access, Audit, ClassTemplate, Paging, Schedule, Venue, Venues}
  alias SimpleFit.Repo

  @unlogged [log: false]

  @doc "The gym's templates, by title (params: `status` `active` (default) or `archived`, `limit`)."
  @spec list(User.t(), term(), map()) :: {:ok, map()} | {:error, Schedule.error()}
  def list(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym}} <- Schedule.read(user, gym_id),
         {:ok, %{limit: limit, status: status}} <-
           Paging.params(Map.delete(params, "cursor"), [:active, :archived], :active) do
      templates =
        Repo.all(
          from(t in ClassTemplate,
            where: t.gym_id == ^gym.id and t.status == ^status,
            order_by: [asc: fragment("lower(?)", t.title), asc: t.id],
            limit: ^limit
          ),
          @unlogged
        )

      {:ok, %{entries: views(templates)}}
    end
  end

  @doc "One template of the gym."
  @spec get(User.t(), term(), term()) :: {:ok, map()} | {:error, Schedule.error()}
  def get(%User{} = user, gym_id, template_id) do
    with {:ok, %{gym: gym}} <- Schedule.read(user, gym_id),
         %ClassTemplate{} = template <- fetch(gym.id, template_id, false) do
      {:ok, hd(views([template]))}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a template (`attrs`: `client_request_id`, `title`,
  `default_duration_minutes`, `default_capacity`, optional `description`,
  `default_venue_id`, `default_instructor_staff_membership_id`). The same
  `client_request_id` again returns the template it created (`:existing`).
  """
  @spec create(User.t(), Session.t(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, Schedule.error()}
  def create(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    Schedule.write(user, session, gym_id, :manage_timetable, &create_in(&1.gym, user, attrs))
    |> tap(&Schedule.emit(:class_template_created, &1))
  end

  defp create_in(gym, user, attrs) do
    with {:ok, params} <- params(attrs, %{}, :create) do
      case Repo.get_by(
             ClassTemplate,
             [gym_id: gym.id, client_request_id: params.client_request_id],
             @unlogged
           ) do
        %ClassTemplate{} = existing -> {:ok, {hd(views([existing])), :existing}}
        nil -> insert(gym.id, user, params)
      end
    end
  end

  defp insert(gym_id, user, params) do
    with :ok <- defaults(gym_id, params) do
      now = DateTime.utc_now()

      template =
        Repo.insert!(
          struct!(
            ClassTemplate,
            Map.merge(params, %{gym_id: gym_id, created_by_user_id: user.id})
          ),
          @unlogged
        )

      audit!(gym_id, user.id, :class_template_created, template, now)
      {:ok, {hd(views([template])), :created}}
    end
  end

  @doc """
  Updates a template's definition and defaults (`attrs`:
  `expected_revision` and any of the create fields but
  `client_request_id`; `null` clears an optional default). Scheduled
  classes are not changed.
  """
  @spec update(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, Schedule.error()}
  def update(%User{} = user, %Session{} = session, gym_id, template_id, attrs)
      when is_map(attrs) do
    Schedule.write(user, session, gym_id, :manage_timetable, fn %{gym: gym} ->
      with %ClassTemplate{} = template <- fetch(gym.id, template_id, true) || {:error, :not_found},
           :ok <- active(template),
           :ok <- Schedule.revision(attrs, template.revision),
           {:ok, changes} <- params(attrs, template, :update),
           :ok <- defaults(gym.id, Map.merge(Map.from_struct(template), changes)) do
        now = DateTime.utc_now()

        updated =
          template
          |> Changeset.change(
            Map.merge(changes, %{revision: template.revision + 1, updated_at: now})
          )
          |> Repo.update!(@unlogged)

        audit!(gym.id, user.id, :class_template_updated, updated, now)
        {:ok, hd(views([updated]))}
      end
    end)
    |> tap(&Schedule.emit(:class_template_updated, &1))
  end

  @doc """
  Archives a template (`attrs`: `expected_revision`): no new classes from
  it; its scheduled classes stay. Archiving it again returns it unchanged.
  """
  @spec archive(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, Schedule.error()}
  def archive(%User{} = user, %Session{} = session, gym_id, template_id, attrs)
      when is_map(attrs) do
    Schedule.write(
      user,
      session,
      gym_id,
      :manage_timetable,
      &archive_in(&1.gym, user, fetch(&1.gym.id, template_id, true), attrs)
    )
    |> tap(&Schedule.emit(:class_template_archived, &1))
  end

  defp archive_in(_gym, _user, nil, _attrs), do: {:error, :not_found}

  defp archive_in(_gym, _user, %ClassTemplate{status: :archived} = template, _attrs),
    do: {:ok, hd(views([template]))}

  defp archive_in(gym, user, %ClassTemplate{} = template, attrs) do
    with :ok <- Schedule.revision(attrs, template.revision) do
      now = DateTime.utc_now()

      archived =
        template
        |> Changeset.change(
          status: :archived,
          archived_at: now,
          revision: template.revision + 1,
          updated_at: now
        )
        |> Repo.update!(@unlogged)

      audit!(gym.id, user.id, :class_template_archived, archived, now)
      {:ok, hd(views([archived]))}
    end
  end

  @doc false
  # The template of `gym_id` by id (`lock?`: `FOR UPDATE`), or `nil`.
  @spec fetch(Ecto.UUID.t(), term(), boolean()) :: ClassTemplate.t() | nil
  def fetch(gym_id, template_id, lock?) do
    case Access.cast_id(template_id) do
      {:ok, id} ->
        query = from(t in ClassTemplate, where: t.id == ^id and t.gym_id == ^gym_id)
        query = if lock?, do: from(t in query, lock: "FOR UPDATE"), else: query
        Repo.one(query, @unlogged)

      :error ->
        nil
    end
  end

  defp active(%ClassTemplate{status: :active}), do: :ok
  defp active(%ClassTemplate{}), do: {:error, {:conflict, %{class_template: "archived"}}}

  # The defaults hold together: an active venue of the gym that fits the
  # default capacity, and an eligible instructor of the gym.
  defp defaults(gym_id, params) do
    with :ok <- default_venue(gym_id, params[:default_venue_id], params[:default_capacity]),
         {:ok, _} <-
           Schedule.instructor(
             gym_id,
             params[:default_instructor_staff_membership_id],
             :default_instructor_staff_membership_id
           ) do
      :ok
    end
  end

  defp default_venue(_gym_id, nil, _capacity), do: :ok

  defp default_venue(gym_id, venue_id, capacity) do
    case Venues.fetch(gym_id, venue_id, false) do
      %Venue{status: :active, capacity: venue_capacity}
      when is_nil(venue_capacity) or venue_capacity >= capacity ->
        :ok

      %Venue{status: :active} ->
        {:error, Schedule.field_error(:default_capacity, "is more than the venue holds", :number)}

      _ ->
        {:error,
         Schedule.field_error(:default_venue_id, "is not an active venue of this gym", :inclusion)}
    end
  end

  ## Params

  @fields ~w(title description default_duration_minutes default_capacity default_venue_id
             default_instructor_staff_membership_id)

  defp types do
    %{
      client_request_id: Ecto.UUID,
      title: :string,
      description: :string,
      default_duration_minutes: :integer,
      default_capacity: :integer,
      default_venue_id: Ecto.UUID,
      default_instructor_staff_membership_id: Ecto.UUID
    }
  end

  defp params(attrs, current, mode) do
    data =
      case current do
        %ClassTemplate{} -> Map.take(current, Enum.map(@fields, &String.to_existing_atom/1))
        _ -> %{}
      end

    {permitted, required, allowed} =
      case mode do
        :create ->
          {Map.keys(types()),
           [:client_request_id, :title, :default_duration_minutes, :default_capacity],
           ["client_request_id" | @fields]}

        :update ->
          {Map.keys(types()) -- [:client_request_id],
           [:title, :default_duration_minutes, :default_capacity],
           ["expected_revision" | @fields]}
      end

    changeset =
      {data, types()}
      |> Changeset.cast(attrs, permitted)
      |> Changeset.validate_required(required)
      |> Schedule.reject_unknown(attrs, allowed)
      |> Changeset.update_change(:title, &String.trim/1)
      |> Changeset.update_change(:description, &blank_to_nil/1)
      |> Changeset.validate_length(:title, min: 1, max: 80)
      |> Changeset.validate_format(:title, ~r/\A[^\p{Cc}\p{Cf}]*\z/u)
      |> Changeset.validate_length(:description, max: 1000)
      |> Changeset.validate_number(:default_duration_minutes,
        greater_than_or_equal_to: 5,
        less_than_or_equal_to: 480
      )
      |> Changeset.validate_number(:default_capacity,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: 500
      )

    case {changeset, mode} do
      {%Changeset{valid?: false}, _} ->
        {:error, changeset}

      {_, :create} ->
        {:ok,
         Map.merge(
           %{
             description: nil,
             default_venue_id: nil,
             default_instructor_staff_membership_id: nil
           },
           Changeset.apply_changes(changeset)
         )}

      {_, :update} ->
        {:ok, changeset.changes}
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  ## Views

  @doc false
  @spec views([ClassTemplate.t()]) :: [map()]
  def views(templates) do
    instructors =
      Schedule.instructors(Enum.map(templates, & &1.default_instructor_staff_membership_id))

    Enum.map(templates, fn t ->
      %{
        template_id: t.id,
        gym_id: t.gym_id,
        title: t.title,
        description: t.description,
        default_duration_minutes: t.default_duration_minutes,
        default_capacity: t.default_capacity,
        default_venue_id: t.default_venue_id,
        default_instructor: Map.get(instructors, t.default_instructor_staff_membership_id),
        status: t.status,
        revision: t.revision,
        created_at: t.inserted_at,
        updated_at: t.updated_at
      }
    end)
  end

  defp audit!(gym_id, actor_id, event, template, now),
    do:
      Audit.record!(
        %{
          gym_id: gym_id,
          actor_user_id: actor_id,
          event_type: event,
          class_template_id: template.id
        },
        now
      )
end
