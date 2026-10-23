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

  Relationships are created only by a fighter accepting a coach's
  invitation (`accept_invitation/3`, SF-57), which calls the trusted
  activation in the same transaction that consumes the invitation.

  Ending also cancels the relationship's planned future training sessions
  (`SimpleFit.Training.cancel_for_relationship/2`, reason
  `relationship_ended`) in the same transaction (ADR 0021, ADR 0023).

  ## Training (ADR 0023)

  `SimpleFit.Training` authorizes every coach-side session operation through
  this context: `training_coach/1`, `lock_training_relationship/3`,
  `active_relationship_ids/1` and the identity projections. Lock order is
  always the relationship row first, then session rows.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaches, Fighters, Repo, Training}
  alias SimpleFit.Coaching.{Invitations, LegalPolicy, Relationship}

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

  ## Invitations (SF-57; `SimpleFit.Coaching.Invitations`)

  @doc "See `SimpleFit.Coaching.Invitations.data_rules/2`."
  defdelegate coach_data_rules(user, language \\ nil), to: Invitations, as: :data_rules

  @doc "See `SimpleFit.Coaching.Invitations.acknowledge_data_rules/2`."
  defdelegate acknowledge_coach_data_rules(user, attrs),
    to: Invitations,
    as: :acknowledge_data_rules

  @doc "See `SimpleFit.Coaching.Invitations.create/3`."
  defdelegate invite(user, attrs, client_ip), to: Invitations, as: :create

  @doc "See `SimpleFit.Coaching.Invitations.coach_view/2`."
  defdelegate invitation_view(invitation), to: Invitations, as: :coach_view

  @doc "See `SimpleFit.Coaching.Invitations.list/2`."
  defdelegate list_invitations(user, params), to: Invitations, as: :list

  @doc "See `SimpleFit.Coaching.Invitations.resend/3`."
  defdelegate resend_invitation(user, id, client_ip), to: Invitations, as: :resend

  @doc "See `SimpleFit.Coaching.Invitations.cancel/2`."
  defdelegate cancel_invitation(user, id), to: Invitations, as: :cancel

  @doc "See `SimpleFit.Coaching.Invitations.preview/3`."
  defdelegate preview_invitation(token, client_ip, language \\ nil),
    to: Invitations,
    as: :preview

  @doc "See `SimpleFit.Coaching.Invitations.list_incoming/2`."
  defdelegate list_incoming_invitations(user, params), to: Invitations, as: :list_incoming

  @doc "See `SimpleFit.Coaching.Invitations.preview_by_id/4`."
  defdelegate preview_incoming_invitation(user, id, client_ip, language \\ nil),
    to: Invitations,
    as: :preview_by_id

  @doc "See `SimpleFit.Coaching.Invitations.accept_by_id/4`."
  defdelegate accept_incoming_invitation(user, id, params, client_ip),
    to: Invitations,
    as: :accept_by_id

  @doc "See `SimpleFit.Coaching.Invitations.decline_by_id/3`."
  defdelegate decline_incoming_invitation(user, id, client_ip),
    to: Invitations,
    as: :decline_by_id

  @doc "See `SimpleFit.Coaching.Invitations.accept/3`."
  defdelegate accept_invitation(user, params, client_ip), to: Invitations, as: :accept

  @doc "See `SimpleFit.Coaching.Invitations.decline/3`."
  defdelegate decline_invitation(user, params, client_ip), to: Invitations, as: :decline

  ## Relationships

  @doc "Whether the sharing gate flag is on (runtime configuration, default `false`). See `sharing_ready?/0`."
  @spec access_enabled?() :: boolean()
  def access_enabled?,
    do: Application.get_env(:simple_fit, __MODULE__, [])[:access_enabled] == true

  @doc """
  Whether Coach–Fighter sharing is available at all: the legal regime of
  `SimpleFit.Coaching.LegalPolicy` is not `:blocked`. Normally (ADR 0022)
  the gate flag is on **and** the legal document registry is valid **and**
  the configured current disclosure and coach data rules are `published`
  there; the flag alone never enables anything. In LOCAL DEVELOPMENT mode
  (ADR 0025) no legal document is involved. Global checks only; each
  acceptance adds its per-invitation and per-user checks (recipient,
  disclosure, age, profiles).
  """
  @spec sharing_ready?() :: boolean()
  def sharing_ready?, do: LegalPolicy.available?()

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
  One of the fighter's own relationships, active or ended, exactly as
  `list_fighter_relationships/2` shows it (SF-74): the coach's live public
  identity while active, the coach's name at the end once ended. One lookup
  by primary key, scoped to the caller's fighter profile; an unknown,
  malformed or foreign id is `:not_found`, as is a user without a completed
  fighter profile. Available whatever the sharing gate says. Each statement
  reads committed data (READ COMMITTED): a read racing an end returns the
  whole active entry or the whole ended stub; a relationship deleted with its
  coach mid-read is `:not_found`.
  """
  @spec get_fighter_relationship(User.t(), term()) ::
          {:ok, fighter_entry()} | {:error, :not_found}
  def get_fighter_relationship(%User{} = user, id) do
    with {:ok, fighter} <- completed(Fighters.get_profile(user)),
         {:ok, id} <- relationship_id(id),
         %Relationship{} = relationship <-
           Repo.one(from(r in owned_by(:fighter, fighter.id), where: r.id == ^id), @unlogged),
         [entry] = fighter_entries([relationship]),
         :ok <- whole(entry) do
      {:ok, entry}
    else
      _ -> {:error, :not_found}
    end
  end

  # A coach profile exists for every relationship row (foreign key, cascade).
  # An active entry without one means the coach was deleted after the row was
  # read, and the relationship with it: never return that half entry.
  defp whole(%{status: :active, coach: nil}), do: :gone
  defp whole(_entry), do: :ok

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

  ## Training sessions (ADR 0023; called by `SimpleFit.Training` only)

  @doc """
  The user's completed coach profile when coach-side training is available:
  Coach–Fighter sharing ready (`sharing_ready?/0`) and a completed coach
  profile. Otherwise `:not_found`, like every coach read.
  """
  @spec training_coach(User.t()) :: {:ok, Coaches.CoachProfile.t()} | {:error, :not_found}
  def training_coach(%User{} = user), do: coach_reader(user)

  @doc """
  Locks (`FOR SHARE`, inside the caller's transaction) and returns the
  coach's relationship `id` when a session may be assigned or planned under
  it: owned by `coach_profile_id`, `active`, and, with `require: :disclosing`
  (create, update), still disclosing something under the version its fighter
  accepted (a withdrawn or unconfigured version discloses nothing, ADR 0022).
  An end (`FOR UPDATE`) waits for the lock, or has already committed and the
  relationship is then not active. Anything else is `:not_found`.
  """
  @spec lock_training_relationship(Ecto.UUID.t(), term(), keyword()) ::
          {:ok,
           %{
             id: Ecto.UUID.t(),
             coach_profile_id: Ecto.UUID.t(),
             fighter_profile_id: Ecto.UUID.t()
           }}
          | {:error, :not_found}
  def lock_training_relationship(coach_profile_id, id, opts \\ []) do
    with {:ok, id} <- relationship_id(id),
         %Relationship{} = r <-
           Repo.one(
             from(r in owned_by(:coach, coach_profile_id),
               where: r.id == ^id and r.status == :active,
               lock: "FOR SHARE"
             ),
             @unlogged
           ),
         true <-
           opts[:require] != :disclosing or
             LegalPolicy.disclosure_fields(r.disclosure_version) != [] do
      {:ok,
       %{id: r.id, coach_profile_id: r.coach_profile_id, fighter_profile_id: r.fighter_profile_id}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  A query of the ids of the coach's active relationships, for
  `SimpleFit.Training` to scope coach reads to them (a former coach reads
  nothing of the sessions, product decision 2026-10-20).
  """
  @spec active_relationship_ids(Ecto.UUID.t()) :: Ecto.Query.t()
  def active_relationship_ids(coach_profile_id) do
    from(r in owned_by(:coach, coach_profile_id), where: r.status == :active, select: r.id)
  end

  @doc """
  The fighter identity a coach sees on sessions, by relationship id: the
  fighter's `display_name` and `username` where the accepted disclosure
  version discloses them (`nil` otherwise). Only the given relationships
  that are active are read.
  """
  @spec training_fighters([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => map()}
  def training_fighters(relationship_ids) do
    relationships =
      Repo.all(
        from(r in Relationship,
          where: r.id in ^Enum.uniq(relationship_ids) and r.status == :active
        ),
        @unlogged
      )

    # One projection per disclosure version, never more than it discloses.
    relationships
    |> Enum.group_by(& &1.disclosure_version)
    |> Enum.flat_map(fn {version, group} ->
      fields =
        Enum.filter(LegalPolicy.disclosure_fields(version), &(&1 in [:display_name, :username]))

      found = Fighters.coach_projection(Enum.map(group, & &1.fighter_profile_id), fields)

      Enum.map(group, fn r ->
        fighter = Map.get(found, r.fighter_profile_id, %{})
        {r.id, %{display_name: fighter[:display_name], username: fighter[:username]}}
      end)
    end)
    |> Map.new()
  end

  @doc """
  The coach identity a fighter sees on their sessions, by relationship id:
  the coach's live public identity while the relationship is active, the
  coach's name as it was at the end once ended (as `list_fighter_relationships/2`).
  """
  @spec training_coaches([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => map()}
  def training_coaches(relationship_ids) do
    relationships =
      Repo.all(from(r in Relationship, where: r.id in ^Enum.uniq(relationship_ids)), @unlogged)

    relationships
    |> fighter_entries()
    |> Map.new(fn entry ->
      {entry.relationship_id,
       %{coach: entry.coach, coach_display_name_at_end: entry.coach_display_name_at_end}}
    end)
  end

  # -- Authorization -------------------------------------------------------

  # Coach reads need sharing to be ready and a completed coach profile.
  defp coach_reader(user) do
    if sharing_ready?(), do: completed(Coaches.get_profile(user)), else: {:error, :not_found}
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

    # SF-49 §6.3: planned future sessions end with the relationship, in this
    # transaction, while its row is still locked (ADR 0023).
    Training.cancel_for_relationship(relationship.id, now)

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
        |> Fighters.coach_projection(LegalPolicy.disclosure_fields(version))
        |> Map.merge(acc)
      end)

    Enum.map(relationships, fn
      %Relationship{status: :active} = r ->
        fields = LegalPolicy.disclosure_fields(r.disclosure_version)
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
        disclosed_fields:
          if(active?, do: LegalPolicy.disclosure_fields(r.disclosure_version), else: []),
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
