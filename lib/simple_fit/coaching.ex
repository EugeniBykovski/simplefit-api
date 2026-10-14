defmodule SimpleFit.Coaching do
  @moduledoc """
  Coach–Fighter coaching relationships and the authorization they carry
  (ADR 0021; SF-49 §6, §10).

  A relationship is the only basis on which a coach may see anything of a
  fighter. It connects the coach's completed coach profile to the fighter's
  completed fighter profile, is created only by the fighter's explicit
  acceptance (`SimpleFit.Coaching.Activation`; never by a coach, never from
  an email match) and ends once, from either side. A fighter may have several
  coaches; a pair has at most one active relationship, and a reconnection is
  a new relationship. Gyms play no part.

  Every function acts for the authenticated user it is given and addresses a
  relationship only by its id, checked against that user's own profile; an id
  of someone else's relationship is indistinguishable from an unknown one
  (`{:error, :not_found}`).

  ## What each side sees

    * **Coach, active relationship**: the fields of the disclosure version
      the fighter accepted (`SimpleFit.Coaching.Disclosure`: C1 identity and
      C2 basic boxing information), never goals, next fight, body data or
      account data.
    * **Coach, ended relationship**: a stub only (dates, who ended it and the
      fighter's display name as it was at the end); no profile field.
    * **Fighter**: their own relationships, the coach's public identity while
      active and the coach's name as it was at the end afterwards.

  ## Gate

  Coach–Fighter sharing is behind `access_enabled` (runtime configuration,
  default `false`; enabled per environment once the approved legal texts and
  disclosure versions are configured). While it is off, no relationship can
  be activated and every coach read answers `:not_found`; ending a
  relationship (either side) and the fighter's own list stay available, and
  no ended relationship ever becomes active again when it is turned on.

  ## Ending and consistency

  Ending locks the relationship row and is idempotent: the first end wins
  (its time and side are kept) and repeating it changes nothing. Every
  authorization check reads the committed state, so an operation that starts
  after an end has been confirmed never sees the relationship as active. A
  read already running when the end commits may still complete with the data
  it was authorized for.

  The future TrainingSession domain hooks into the end transaction
  (`end_relationship/3`) to cancel planned sessions with reason
  `relationship_ended` (ADR 0021); no training data exists yet.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaches, Fighters, Repo}
  alias SimpleFit.Coaching.{Disclosure, Relationship}

  # Relationship rows and projections carry personal data; not logged.
  @unlogged [log: false]

  @default_limit 50
  @max_limit 100

  @typedoc "One relationship as its coach sees it."
  @type coach_entry :: %{
          relationship_id: Ecto.UUID.t(),
          status: Relationship.status(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          ended_by: Relationship.party() | nil,
          disclosure_version: String.t() | nil,
          disclosed_fields: [atom()],
          fighter: map() | nil,
          fighter_display_name_at_end: String.t() | nil
        }

  @typedoc "One relationship as its fighter sees it."
  @type fighter_entry :: %{
          relationship_id: Ecto.UUID.t(),
          status: Relationship.status(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          ended_by: Relationship.party() | nil,
          disclosure_version: String.t(),
          disclosed_fields: [atom()],
          coach: map() | nil,
          coach_display_name_at_end: String.t() | nil
        }

  @typedoc "A page of entries and the cursor of the next one (`nil` on the last page)."
  @type page(entry) :: %{entries: [entry], next_cursor: String.t() | nil}

  @doc "Whether new Coach–Fighter sharing is enabled (runtime configuration, default `false`)."
  @spec access_enabled?() :: boolean()
  def access_enabled?,
    do: Application.get_env(:simple_fit, __MODULE__, [])[:access_enabled] == true

  @doc """
  The coach's relationships, newest first: `status` `"active"` (default,
  with the disclosed fighter fields) or `"ended"` (stubs). Params (string
  keys): `status`, `limit` (1..100, default 50), `cursor` (from the previous
  page). `:not_found` unless sharing is enabled and the user's coach profile
  is completed.
  """
  @spec list_coach_relationships(User.t(), map()) ::
          {:ok, page(coach_entry())} | {:error, :not_found | Ecto.Changeset.t()}
  def list_coach_relationships(%User{} = user, params) when is_map(params) do
    with {:ok, coach} <- coach_reader(user),
         {:ok, query} <- page_params(params) do
      {:ok, page(owned_by(:coach, coach.id), query, &coach_entries/1)}
    end
  end

  @doc """
  One active relationship of the coach, with the disclosed fighter fields.
  An ended, unknown or foreign relationship is `:not_found`, as is every
  call while sharing is disabled or the coach profile is not completed.
  """
  @spec get_coach_relationship(User.t(), String.t()) ::
          {:ok, coach_entry()} | {:error, :not_found}
  def get_coach_relationship(%User{} = user, id) do
    with {:ok, coach} <- coach_reader(user),
         {:ok, id} <- relationship_id(id),
         %Relationship{} = relationship <-
           Repo.one(
             from(r in owned_by(:coach, coach.id), where: r.id == ^id and r.status == :active),
             @unlogged
           ) do
      [entry] = coach_entries([relationship])
      {:ok, entry}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The fighter's own relationships, newest first: `status` `"active"`
  (default) or `"ended"`; same paging params as
  `list_coach_relationships/2`. `:not_found` unless the user's fighter
  profile is completed. Available whatever the sharing gate says.
  """
  @spec list_fighter_relationships(User.t(), map()) ::
          {:ok, page(fighter_entry())} | {:error, :not_found | Ecto.Changeset.t()}
  def list_fighter_relationships(%User{} = user, params) when is_map(params) do
    with {:ok, fighter} <- completed(Fighters.get_profile(user)),
         {:ok, query} <- page_params(params) do
      {:ok, page(owned_by(:fighter, fighter.id), query, &fighter_entries/1)}
    end
  end

  @doc """
  Ends one of the user's relationships as `side` (`:coach` or `:fighter`).
  Idempotent: an already ended relationship stays as it ended. Available
  whatever the sharing gate says; `:not_found` for an unknown or foreign
  relationship, or when the user has no completed profile for `side`.
  """
  @spec end_relationship(User.t(), Relationship.party(), String.t()) :: :ok | {:error, :not_found}
  def end_relationship(%User{} = user, side, id) when side in [:coach, :fighter] do
    with {:ok, profile} <- party_profile(user, side),
         {:ok, id} <- relationship_id(id) do
      Repo.transaction(fn -> end_locked(side, profile.id, id) end, @unlogged)
      |> ended(side)
    end
  end

  defp ended({:ok, :ended}, side) do
    :telemetry.execute([:simple_fit, :coaching, :relationship, :ended], %{count: 1}, %{
      ended_by: side
    })

    :ok
  end

  defp ended({:ok, :already_ended}, _side), do: :ok
  defp ended({:error, :not_found}, _side), do: {:error, :not_found}

  # -- Authorization -------------------------------------------------------

  # Coach reads need the sharing gate and a completed coach profile.
  defp coach_reader(user) do
    if access_enabled?(), do: completed(Coaches.get_profile(user)), else: {:error, :not_found}
  end

  defp party_profile(user, :coach), do: completed(Coaches.get_profile(user))
  defp party_profile(user, :fighter), do: completed(Fighters.get_profile(user))

  defp completed(%{onboarding_completed_at: %DateTime{}} = profile), do: {:ok, profile}
  defp completed(_profile), do: {:error, :not_found}

  defp relationship_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp relationship_id(_id), do: {:error, :not_found}

  defp owned_by(:coach, profile_id),
    do: from(r in Relationship, where: r.coach_profile_id == ^profile_id)

  defp owned_by(:fighter, profile_id),
    do: from(r in Relationship, where: r.fighter_profile_id == ^profile_id)

  # -- Ending --------------------------------------------------------------

  defp end_locked(side, profile_id, id) do
    from(r in owned_by(side, profile_id), where: r.id == ^id, lock: "FOR UPDATE")
    |> Repo.one(@unlogged)
    |> case do
      nil -> Repo.rollback(:not_found)
      %Relationship{status: :ended} -> :already_ended
      %Relationship{} = relationship -> end!(relationship, side)
    end
  end

  # The minimum history (SF-49 §6.4.4): each side's name as it is now.
  defp end!(relationship, side) do
    fighter =
      Fighters.coach_projection([relationship.fighter_profile_id], [:display_name])
      |> Map.get(relationship.fighter_profile_id, %{})

    coach =
      Coaches.public_projection([relationship.coach_profile_id])
      |> Map.get(relationship.coach_profile_id, %{})

    now = DateTime.utc_now()

    {1, _} =
      Repo.update_all(
        from(r in Relationship, where: r.id == ^relationship.id and r.status == :active),
        [
          set: [
            status: :ended,
            ended_at: now,
            ended_by: side,
            fighter_display_name_at_end: fighter[:display_name],
            coach_display_name_at_end: coach[:display_name],
            updated_at: now
          ]
        ],
        @unlogged
      )

    :ended
  end

  # -- Projections ---------------------------------------------------------

  defp coach_entries(relationships) do
    active = Enum.filter(relationships, &(&1.status == :active))

    projections =
      active
      |> Enum.group_by(& &1.disclosure_version)
      |> Enum.reduce(%{}, fn {version, group}, acc ->
        group
        |> Enum.map(& &1.fighter_profile_id)
        |> Fighters.coach_projection(Disclosure.fields(version))
        |> Map.merge(acc)
      end)

    Enum.map(relationships, fn
      %Relationship{status: :active} = r ->
        fields = Disclosure.fields(r.disclosure_version)
        found = Map.get(projections, r.fighter_profile_id, %{})

        base(r)
        |> Map.merge(%{
          disclosure_version: r.disclosure_version,
          disclosed_fields: fields,
          fighter: Map.new(Fighters.coach_visible_fields(), &{&1, found[&1]}),
          fighter_display_name_at_end: nil
        })

      %Relationship{status: :ended} = r ->
        base(r)
        |> Map.merge(%{
          disclosure_version: nil,
          disclosed_fields: [],
          fighter: nil,
          fighter_display_name_at_end: r.fighter_display_name_at_end
        })
    end)
  end

  defp fighter_entries(relationships) do
    coaches =
      relationships
      |> Enum.filter(&(&1.status == :active))
      |> Enum.map(& &1.coach_profile_id)
      |> Coaches.public_projection()

    Enum.map(relationships, fn r ->
      active? = r.status == :active

      base(r)
      |> Map.merge(%{
        disclosure_version: r.disclosure_version,
        disclosed_fields: if(active?, do: Disclosure.fields(r.disclosure_version), else: []),
        coach: if(active?, do: Map.get(coaches, r.coach_profile_id)),
        coach_display_name_at_end: r.coach_display_name_at_end
      })
    end)
  end

  defp base(%Relationship{} = r) do
    %{
      relationship_id: r.id,
      status: r.status,
      started_at: r.started_at,
      ended_at: r.ended_at,
      ended_by: r.ended_by
    }
  end

  # -- Paging --------------------------------------------------------------

  @page_types %{status: :string, limit: :integer, cursor: :string}

  defp page_params(params) do
    changeset =
      {%{status: "active", limit: @default_limit, cursor: nil}, @page_types}
      |> Ecto.Changeset.cast(params, Map.keys(@page_types))
      |> Ecto.Changeset.validate_inclusion(:status, ["active", "ended"])
      |> Ecto.Changeset.validate_number(:limit,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: @max_limit
      )
      |> validate_cursor()

    if changeset.valid? do
      query = Ecto.Changeset.apply_changes(changeset)
      {:ok, %{query | status: String.to_existing_atom(query.status)}}
    else
      {:error, changeset}
    end
  end

  defp validate_cursor(changeset) do
    with cursor when is_binary(cursor) <- Ecto.Changeset.get_change(changeset, :cursor),
         status = Ecto.Changeset.get_field(changeset, :status),
         {:ok, position} <- decode_cursor(cursor, status) do
      Ecto.Changeset.put_change(changeset, :cursor, position)
    else
      nil -> changeset
      :error -> Ecto.Changeset.add_error(changeset, :cursor, "is invalid", validation: :format)
    end
  end

  # Active pages are ordered by start, ended pages by end; ties by id.
  defp page(base_query, %{status: status, limit: limit, cursor: cursor}, to_entries) do
    rows =
      from(r in base_query, where: r.status == ^status, limit: ^(limit + 1))
      |> order_and_seek(status, cursor)
      |> Repo.all(@unlogged)

    {rows, rest} = Enum.split(rows, limit)
    next = if rest == [], do: nil, else: encode_cursor(List.last(rows), status)
    %{entries: to_entries.(rows), next_cursor: next}
  end

  defp order_and_seek(query, :active, nil),
    do: from(r in query, order_by: [desc: r.started_at, desc: r.id])

  defp order_and_seek(query, :active, {at, id}),
    do:
      from(r in order_and_seek(query, :active, nil),
        where: r.started_at < ^at or (r.started_at == ^at and r.id < ^id)
      )

  defp order_and_seek(query, :ended, nil),
    do: from(r in query, order_by: [desc: r.ended_at, desc: r.id])

  defp order_and_seek(query, :ended, {at, id}),
    do:
      from(r in order_and_seek(query, :ended, nil),
        where: r.ended_at < ^at or (r.ended_at == ^at and r.id < ^id)
      )

  # An opaque position: the status it pages, the sort time and the id of the
  # last entry shown. It grants nothing; every page is still scoped to the
  # caller's own relationships.
  defp encode_cursor(%Relationship{} = r, status) do
    at = if status == :active, do: r.started_at, else: r.ended_at

    Base.url_encode64("#{status}|#{DateTime.to_unix(at, :microsecond)}|#{r.id}", padding: false)
  end

  defp decode_cursor(cursor, status) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [^status, micros, id] <- String.split(decoded, "|"),
         {micros, ""} <- Integer.parse(micros),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :error
    end
  end
end
