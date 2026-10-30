defmodule SimpleFit.Gyms.Members do
  @moduledoc """
  Gym members (participants): enrollment by join code, the staff's decision
  on requests, the roster, leaving and removal, and the gym's enrollment
  settings (ADR 0026, D-G07, D-G08; SF-95). Internal to `SimpleFit.Gyms`.
  Member invitations are `SimpleFit.Gyms.MemberInvitations`; the member list
  preview is `SimpleFit.Gyms.MemberImport`.

  ## Domain

  A gym membership (`SimpleFit.Gyms.Member`) is independent of staff
  memberships, Fighter and Coach profiles and Coach–Fighter relationships:
  none is required, created, read or changed here. Joining needs only a
  completed account (D-G07). A membership grants no gym permission and no
  gym workspace (entry, SF-84, reads staff memberships only).

  ## Enrollment (D-G08, T10)

    * **Join code:** a signed-in user with a completed account enters the
      gym's code. The result is a `requested` membership that the gym's
      owner, managers or front desk approve or reject
      (`manage_member_enrollment`). Only when an owner or manager has
      explicitly enabled auto-approval (`manage_enrollment_settings`; off by
      default, audited) does the membership start `active`, and even then
      only for a user holding a verified sign-in identity
      (`SimpleFit.Accounts.verified_identity?/1`); otherwise it is a
      request. Rotating the code stops the old one at once; disabling it
      stops joining by code.
    * **Invitation:** see `SimpleFit.Gyms.MemberInvitations`.

  The requester may cancel their request; a rejected or cancelled request
  is final, and a new join creates a new request.

  ## Lifecycle

  `requested` -> `active` | `rejected` | `cancelled`; `active` -> `ended`
  (`left` by the member, `removed` by an owner or manager,
  `change_member_status`). Final rows never change and are never deleted;
  re-enrolling creates a new row (history). Every transition is idempotent
  for its own result (approving an active membership, rejecting a rejected
  request, leaving an ended membership return the row unchanged) and a
  conflict for any other (`gym_member: <status>`).

  ## Roster privacy

  Staff see a short name ("Marta K."), the status, how and when the person
  joined and how it ended: never an email, a user id, a profile, another
  gym or any training data (D-G06). The roster needs `view_members`: owner,
  managers and front desk; a coach's grant is scoped to their own classes,
  and no class domain exists yet, so coaches are refused (`forbidden`)
  rather than shown an empty list.

  ## Locks

  Staff decisions take the gym row `FOR UPDATE` and the actor's staff
  membership (`Access.authorize_locked/3`, the SF-83 order), then the member
  row. A member's own changes take their session (`FOR SHARE`), the gym row
  `FOR SHARE`, the enrollment settings (`FOR SHARE`, joins only), then the
  member rows. So a staff decision and a member's change at one gym
  serialize, members' own changes do not wait on each other, and the partial
  unique index on `(gym_id, user_id)` settles two simultaneous joins.

  ## Abuse limits (T10)

  Code previews and joins: 20 per 10 minutes per client and 10 per 10
  minutes per user, counted on every attempt (so guessing codes is bounded:
  40 bits against at most a few thousand tries a day). Staff decisions and
  setting changes: 120 per 10 minutes per user.

  Nothing here logs a code, a name or an id.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.{Accounts, RateLimit, Repo}
  alias SimpleFit.Accounts.{Session, User}

  alias SimpleFit.Gyms.{
    Access,
    Audit,
    EnrollmentSettings,
    Gym,
    Member,
    MemberSecrets,
    Paging,
    Policy
  }

  @unlogged [log: false]

  @type error ::
          :not_found
          | :forbidden
          | :session_revoked
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | Changeset.t()

  @type page :: %{entries: [map()], next_cursor: String.t() | nil}

  ## Roster (staff)

  @doc """
  The gym's members, oldest first (params: `status` `active` (default) or
  `ended`, `limit`, `cursor`). See the moduledoc for who may read it.
  """
  @spec list(User.t(), term(), map()) :: {:ok, page()} | {:error, error()}
  def list(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym}} <- roster_access(user, gym_id),
         {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, [:active, :ended], :active) do
      field = if status == :active, do: :activated_at, else: :ended_at

      from(m in Member,
        where: m.gym_id == ^gym.id and m.status == ^status,
        order_by: [{:asc, field(m, ^field)}, asc: m.id],
        limit: ^(limit + 1)
      )
      |> Paging.seek(cursor, field, :asc)
      |> Repo.all(@unlogged)
      |> page(limit, field, &staff_view/2)
    end
  end

  @doc "One membership of the gym, in any status, for those who may read the roster."
  @spec get(User.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def get(%User{} = user, gym_id, member_id) do
    with {:ok, %{gym: gym}} <- roster_access(user, gym_id),
         {:ok, id} <- found(Access.cast_id(member_id)),
         %Member{} = member <-
           Repo.one(from(m in Member, where: m.id == ^id and m.gym_id == ^gym.id), @unlogged) do
      {:ok, staff_view(member, names([member]))}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp roster_access(user, gym_id) do
    case Access.authorize(user, gym_id, :view_members) do
      {:ok, %{scope: :all} = access} -> {:ok, access}
      # A coach sees the members of their own classes; no class exists yet.
      {:ok, %{scope: _scoped}} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Join requests (staff)

  @doc """
  The gym's pending join requests, oldest first (params: `limit`, `cursor`).
  Owner, managers and front desk (`manage_member_enrollment`).
  """
  @spec list_requests(User.t(), term(), map()) :: {:ok, page()} | {:error, error()}
  def list_requests(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym}} <- Access.authorize(user, gym_id, :manage_member_enrollment),
         {:ok, %{limit: limit, cursor: cursor}} <- Paging.params(params, [:requested]) do
      from(m in Member,
        where: m.gym_id == ^gym.id and m.status == :requested,
        order_by: [asc: m.requested_at, asc: m.id],
        limit: ^(limit + 1)
      )
      |> Paging.seek(cursor, :requested_at, :asc)
      |> Repo.all(@unlogged)
      |> page(limit, :requested_at, &staff_view/2)
    end
  end

  @doc "Approves a join request: `requested` -> `active` (see the moduledoc)."
  @spec approve(User.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def approve(%User{} = user, gym_id, member_id),
    do: decide(user, gym_id, member_id, :manage_member_enrollment, :approve)

  @doc "Rejects a join request: `requested` -> `rejected` (final)."
  @spec reject(User.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def reject(%User{} = user, gym_id, member_id),
    do: decide(user, gym_id, member_id, :manage_member_enrollment, :reject)

  @doc """
  Ends an active membership as the gym (`removed`): owner and managers
  (`change_member_status`).
  """
  @spec remove(User.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def remove(%User{} = user, gym_id, member_id),
    do: decide(user, gym_id, member_id, :change_member_status, :remove)

  defp decide(user, gym_id, member_id, permission, action) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym}} <- Access.authorize_locked(user, gym_id, permission),
             {:ok, member} <- lock_of_gym(gym.id, member_id),
             :ok <- admin_limit(user),
             {:ok, member} <- transition(member, action, user.id, DateTime.utc_now()) do
          staff_view(member, names([member]))
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
    |> tap(&emit(action, &1))
  end

  ## Member side

  @doc """
  The caller's own gym memberships, in every status, newest first, with
  each gym's name (params: `status`, `limit`, `cursor`). Read only from the
  session's user.
  """
  @spec list_mine(User.t(), map()) :: {:ok, page()} | {:error, error()}
  def list_mine(%User{id: user_id}, params) when is_binary(user_id) and is_map(params) do
    with {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, Member.statuses()) do
      rows =
        from(m in Member,
          where: m.user_id == ^user_id,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^(limit + 1)
        )
        |> then(&if(status, do: from(m in &1, where: m.status == ^status), else: &1))
        |> Paging.seek(cursor, :inserted_at, :desc)
        |> Repo.all(@unlogged)

      {rows, next} = Paging.page(rows, limit, :inserted_at)
      gyms = gym_names(rows)
      {:ok, %{entries: Enum.map(rows, &own_view(&1, gyms)), next_cursor: next}}
    end
  end

  @doc "One of the caller's own memberships (`:not_found` for anyone else's)."
  @spec get_mine(User.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def get_mine(%User{id: user_id}, member_id) when is_binary(user_id) do
    with {:ok, id} <- found(Access.cast_id(member_id)),
         %Member{} = member <-
           Repo.one(from(m in Member, where: m.id == ^id and m.user_id == ^user_id), @unlogged) do
      {:ok, own_view(member, gym_names([member]))}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  What a join code shows before joining (no sign-in needed): the gym's name
  and whether a request needs the staff's approval. Unknown, malformed and
  disabled codes are all `:not_found`.
  """
  @spec preview_join(term(), String.t()) :: {:ok, map()} | {:error, error()}
  def preview_join(code, client_ip) when is_binary(client_ip) do
    result =
      with :ok <- join_limit(client_ip, nil),
           {:ok, settings} <- settings_by_code(code),
           %Gym{setup_status: :completed} = gym <- Repo.get(Gym, settings.gym_id, @unlogged) do
        {:ok,
         %{gym: %{gym_id: gym.id, name: gym.name}, requires_approval: !settings.auto_approve}}
      else
        {:error, {:rate_limited, _}} = limited -> limited
        _ -> {:error, :not_found}
      end

    emit(:join_previewed, result)
    result
  end

  @doc """
  Joins the gym of `code` for the signed-in user on `session` (see the
  moduledoc). `{:ok, view, :created}` with a new `requested` (or, with the
  gym's auto-approval and a verified identity, `active`) membership, or
  `{:ok, view, :existing}` for the caller's pending request at that gym. An
  active membership is `409` (`gym_member: already_active`).
  """
  @spec join(User.t(), Session.t(), term(), String.t()) ::
          {:ok, map(), :created | :existing} | {:error, error()}
  def join(%User{} = user, %Session{} = session, code, client_ip) when is_binary(client_ip) do
    result =
      with :ok <- join_limit(client_ip, user),
           {:ok, settings} <- settings_by_code(code) do
        Repo.transaction(fn -> join_locked(user, session, settings) end, @unlogged)
      end

    case result do
      {:ok, {view, outcome}} ->
        emit(:joined, {:ok, outcome})
        {:ok, view, outcome}

      {:error, _} = error ->
        emit(:joined, error)
        error
    end
  end

  defp join_locked(user, session, %EnrollmentSettings{gym_id: gym_id, join_code_digest: digest}) do
    with :ok <- held(Accounts.hold_active_session(user, session)),
         %Gym{setup_status: :completed} = gym <- Access.lock_gym_shared!(gym_id),
         # The code may have been rotated or disabled since it was looked up.
         %EnrollmentSettings{join_code_digest: ^digest} = settings <-
           lock_settings(gym.id, "FOR SHARE"),
         :ok <- registered(user) do
      now = DateTime.utc_now()

      case lock_current(gym.id, user.id) do
        %Member{status: :requested} = existing ->
          {own_view(existing, %{gym.id => gym.name}), :existing}

        %Member{status: :active} ->
          Repo.rollback({:conflict, %{gym_member: "already_active"}})

        nil ->
          auto? = settings.auto_approve and Accounts.verified_identity?(user)
          {member, outcome} = insert_join!(gym, user, auto?, now)
          {own_view(member, %{gym.id => gym.name}), outcome}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
      _gone -> Repo.rollback(:not_found)
    end
  end

  # The partial unique index settles a concurrent join (or acceptance) by the
  # same user: the loser waits for the winner's commit, inserts nothing and
  # answers with the winner's row.
  defp insert_join!(gym, user, auto?, now) do
    row = %{
      id: Ecto.UUID.generate(),
      gym_id: gym.id,
      user_id: user.id,
      status: if(auto?, do: :active, else: :requested),
      joined_via: :join_code,
      auto_approved: auto?,
      requested_at: now,
      activated_at: if(auto?, do: now),
      inserted_at: now,
      updated_at: now
    }

    case insert_member(row) do
      {:ok, member} ->
        audit!(gym.id, user.id, :member_join_requested, member, now)
        if auto?, do: audit!(gym.id, user.id, :member_join_auto_approved, member, now)
        {member, :created}

      :conflict ->
        case lock_current(gym.id, user.id) do
          %Member{status: :requested} = existing -> {existing, :existing}
          _active -> Repo.rollback({:conflict, %{gym_member: "already_active"}})
        end
    end
  end

  @doc false
  # Inserts a membership row unless the user already has a current one at
  # that gym (`:conflict`). Used by joins and invitation acceptances.
  @spec insert_member(map()) :: {:ok, Member.t()} | :conflict
  def insert_member(row) do
    case Repo.insert_all(
           Member,
           [row],
           Keyword.merge(@unlogged,
             on_conflict: :nothing,
             conflict_target:
               {:unsafe_fragment, "(gym_id, user_id) WHERE status IN ('requested', 'active')"},
             returning: true
           )
         ) do
      {1, [member]} -> {:ok, member}
      {0, _} -> :conflict
    end
  end

  @doc false
  # The user's requested or active membership at a gym, locked.
  @spec lock_current(Ecto.UUID.t(), Ecto.UUID.t()) :: Member.t() | nil
  def lock_current(gym_id, user_id) do
    Repo.one(
      from(m in Member,
        where:
          m.gym_id == ^gym_id and m.user_id == ^user_id and m.status in [:requested, :active],
        lock: "FOR UPDATE"
      ),
      @unlogged
    )
  end

  @doc "Withdraws the caller's own pending join request (`cancelled`, final)."
  @spec cancel_request(User.t(), Session.t(), term()) :: {:ok, map()} | {:error, error()}
  def cancel_request(%User{} = user, %Session{} = session, member_id),
    do: own_transition(user, session, member_id, :cancel)

  @doc "Ends the caller's own active membership (`ended`, reason `left`)."
  @spec leave(User.t(), Session.t(), term()) :: {:ok, map()} | {:error, error()}
  def leave(%User{} = user, %Session{} = session, member_id),
    do: own_transition(user, session, member_id, :leave)

  defp own_transition(user, session, member_id, action) do
    Repo.transaction(
      fn ->
        with :ok <- held(Accounts.hold_active_session(user, session)),
             {:ok, id} <- found(Access.cast_id(member_id)),
             %Member{gym_id: gym_id} <-
               Repo.one(
                 from(m in Member, where: m.id == ^id and m.user_id == ^user.id),
                 @unlogged
               ),
             %Gym{} = gym <- Access.lock_gym_shared!(gym_id),
             %Member{} = member <-
               Repo.one(
                 from(m in Member,
                   where: m.id == ^id and m.user_id == ^user.id,
                   lock: "FOR UPDATE"
                 ),
                 @unlogged
               ),
             {:ok, member} <- transition(member, action, user.id, DateTime.utc_now()) do
          own_view(member, %{gym.id => gym.name})
        else
          {:error, reason} -> Repo.rollback(reason)
          nil -> Repo.rollback(:not_found)
        end
      end,
      @unlogged
    )
    |> tap(&emit(action, &1))
  end

  ## Transitions

  @transitions %{
    approve: {:requested, :active, :member_join_approved},
    reject: {:requested, :rejected, :member_join_rejected},
    cancel: {:requested, :cancelled, :member_join_cancelled},
    remove: {:active, :ended, :member_ended},
    leave: {:active, :ended, :member_ended}
  }

  defp transition(%Member{status: status} = member, action, actor_id, now) do
    {from, to, event} = Map.fetch!(@transitions, action)

    cond do
      status == to and same_end?(member, action) -> {:ok, member}
      status == from -> {:ok, apply_transition!(member, action, to, event, actor_id, now)}
      true -> {:error, {:conflict, %{gym_member: Atom.to_string(status)}}}
    end
  end

  # Leaving after a removal (or the reverse) is a conflict, not a repeat.
  defp same_end?(%Member{status: :ended, ended_reason: reason}, action),
    do: reason == end_reason(action)

  defp same_end?(_member, _action), do: true

  defp end_reason(:leave), do: :left
  defp end_reason(:remove), do: :removed
  defp end_reason(_action), do: nil

  defp apply_transition!(member, action, to, event, actor_id, now) do
    changes =
      case to do
        :active -> [status: :active, activated_at: now]
        :ended -> [status: :ended, ended_at: now, ended_reason: end_reason(action)]
        final -> [status: final, responded_at: now]
      end

    changed = activate!(member, changes, now)
    audit!(member.gym_id, actor_id, event, changed, now)
    changed
  end

  @doc false
  # Writes a member transition (`changes`) and returns the new row.
  @spec activate!(Member.t(), keyword(), DateTime.t()) :: Member.t()
  def activate!(%Member{id: id}, changes, now) do
    {1, [changed]} =
      Repo.update_all(
        from(m in Member, where: m.id == ^id, select: m),
        [set: Keyword.put(changes, :updated_at, now)],
        @unlogged
      )

    changed
  end

  defp lock_of_gym(gym_id, member_id) do
    with {:ok, id} <- found(Access.cast_id(member_id)),
         %Member{} = member <-
           Repo.one(
             from(m in Member, where: m.id == ^id and m.gym_id == ^gym_id, lock: "FOR UPDATE"),
             @unlogged
           ) do
      {:ok, member}
    else
      _ -> {:error, :not_found}
    end
  end

  ## Enrollment settings

  @doc """
  The gym's enrollment settings: the join code (as shown, `ABCD-EFGH`, or
  `nil` when joining by code is off), whether auto-approval is on, and
  whether the viewer may change them. Owner, managers and front desk (the
  front desk shows the code at the desk).
  """
  @spec get_settings(User.t(), term()) :: {:ok, map()} | {:error, error()}
  def get_settings(%User{} = user, gym_id) do
    with {:ok, %{gym: gym, membership: membership}} <-
           Access.authorize(user, gym_id, :manage_member_enrollment) do
      settings = Repo.get(EnrollmentSettings, gym.id, @unlogged)
      {:ok, settings_view(gym, settings, membership)}
    end
  end

  @doc """
  Issues a new join code (the previous one stops working at once) and
  enables joining by code. Owner and managers; completed gyms only.
  """
  @spec rotate_join_code(User.t(), term()) :: {:ok, map()} | {:error, error()}
  def rotate_join_code(%User{} = user, gym_id) do
    change_settings(user, gym_id, fn gym, settings, now ->
      code = MemberSecrets.generate_join_code()

      updated =
        upsert_settings!(gym.id, settings, now,
          join_code_digest: MemberSecrets.join_code_digest(code),
          join_code_sealed: MemberSecrets.seal_join_code(code),
          join_code_rotated_at: now
        )

      Audit.record!(
        %{gym_id: gym.id, actor_user_id: user.id, event_type: :join_code_rotated},
        now
      )

      updated
    end)
  end

  @doc "Disables joining by code (no code). Repeating it changes nothing."
  @spec disable_join_code(User.t(), term()) :: {:ok, map()} | {:error, error()}
  def disable_join_code(%User{} = user, gym_id) do
    change_settings(user, gym_id, fn
      gym, %EnrollmentSettings{join_code_digest: digest} = settings, now when is_binary(digest) ->
        updated =
          upsert_settings!(gym.id, settings, now,
            join_code_digest: nil,
            join_code_sealed: nil
          )

        Audit.record!(
          %{gym_id: gym.id, actor_user_id: user.id, event_type: :join_code_disabled},
          now
        )

        updated

      _gym, settings, _now ->
        settings
    end)
  end

  @doc """
  Changes the enrollment settings (`attrs`: `"auto_approve"` boolean,
  nothing else). Turning auto-approval on or off is audited; the same value
  again changes nothing. Owner and managers.
  """
  @spec update_settings(User.t(), term(), map()) :: {:ok, map()} | {:error, error()}
  def update_settings(%User{} = user, gym_id, attrs) when is_map(attrs) do
    with {:ok, auto_approve} <- auto_approve_param(attrs) do
      change_settings(user, gym_id, &set_auto_approve(&1, &2, &3, user, auto_approve))
    end
  end

  defp set_auto_approve(gym, settings, now, user, auto_approve) do
    if ((settings && settings.auto_approve) || false) == auto_approve do
      settings
    else
      updated =
        upsert_settings!(gym.id, settings, now,
          auto_approve: auto_approve,
          auto_approve_changed_at: now
        )

      Audit.record!(
        %{
          gym_id: gym.id,
          actor_user_id: user.id,
          event_type: :member_auto_approval_changed,
          enabled: auto_approve
        },
        now
      )

      updated
    end
  end

  defp change_settings(user, gym_id, fun) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym, membership: membership}} <-
               Access.authorize_locked(user, gym_id, :manage_enrollment_settings),
             :ok <- completed(gym),
             :ok <- admin_limit(user) do
          settings = lock_settings(gym.id, "FOR UPDATE")
          settings_view(gym, fun.(gym, settings, DateTime.utc_now()), membership)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
    |> tap(&emit(:settings_changed, &1))
  end

  defp upsert_settings!(gym_id, nil, now, changes) do
    Repo.insert!(
      struct!(EnrollmentSettings, [gym_id: gym_id, inserted_at: now, updated_at: now] ++ changes),
      @unlogged
    )
  end

  defp upsert_settings!(_gym_id, %EnrollmentSettings{} = settings, now, changes) do
    settings
    |> Changeset.change(Keyword.put(changes, :updated_at, now))
    |> Repo.update!(@unlogged)
  end

  # A join holds the settings `FOR SHARE` (after the gym row), a setting
  # change `FOR UPDATE` (after the gym row, which it holds for update).
  defp lock_settings(gym_id, "FOR SHARE") do
    Repo.one(
      from(s in EnrollmentSettings, where: s.gym_id == ^gym_id, lock: "FOR SHARE"),
      @unlogged
    )
  end

  defp lock_settings(gym_id, "FOR UPDATE") do
    Repo.one(
      from(s in EnrollmentSettings, where: s.gym_id == ^gym_id, lock: "FOR UPDATE"),
      @unlogged
    )
  end

  defp settings_by_code(code) do
    with {:ok, canonical} <- MemberSecrets.normalize_join_code(code),
         digest = MemberSecrets.join_code_digest(canonical),
         %EnrollmentSettings{} = settings <-
           Repo.one(
             from(s in EnrollmentSettings, where: s.join_code_digest == ^digest),
             @unlogged
           ) do
      {:ok, settings}
    else
      _ -> {:error, :not_found}
    end
  end

  defp auto_approve_param(attrs) do
    changeset =
      {%{}, %{auto_approve: :boolean}}
      |> Changeset.cast(attrs, [:auto_approve])
      |> Changeset.validate_required([:auto_approve])
      |> reject_unknown_fields(attrs, ["auto_approve"])

    if changeset.valid?,
      do: {:ok, Changeset.get_field(changeset, :auto_approve)},
      else: {:error, changeset}
  end

  @doc false
  # Any field outside `allowed` is refused under its own name, without
  # creating atoms or echoing its value.
  @spec reject_unknown_fields(Changeset.t(), map(), [String.t()]) :: Changeset.t()
  def reject_unknown_fields(changeset, attrs, allowed) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a permitted field", []}} | acc.errors], valid?: false}
    end)
  end

  ## Helpers

  defp completed(%Gym{setup_status: :completed}), do: :ok
  defp completed(%Gym{}), do: {:error, {:conflict, %{setup_status: "draft"}}}

  @doc false
  # Joining (or accepting an invitation) needs a completed account (ADR 0016,
  # D-G07) and nothing else: no Fighter or Coach profile.
  @spec registered(User.t()) :: :ok | {:error, Changeset.t()}
  def registered(user) do
    if Accounts.registration_complete?(user) do
      :ok
    else
      {:error,
       {%{}, %{account_registration: :string}}
       |> Changeset.change()
       |> Changeset.add_error(:account_registration, "must be completed first",
         validation: :required
       )}
    end
  end

  @doc false
  # A session revoked or expired while the request ran: `401`.
  @spec held(:ok | {:error, :unauthorized}) :: :ok | {:error, :session_revoked}
  def held(:ok), do: :ok
  def held({:error, :unauthorized}), do: {:error, :session_revoked}

  @doc false
  @spec audit!(Ecto.UUID.t(), Ecto.UUID.t(), atom(), Member.t(), DateTime.t(), map()) :: :ok
  def audit!(gym_id, actor_user_id, event_type, member, now, extra \\ %{}) do
    Audit.record!(
      Map.merge(
        %{
          gym_id: gym_id,
          actor_user_id: actor_user_id,
          event_type: event_type,
          gym_member_id: member.id,
          reason: member.ended_reason
        },
        extra
      ),
      now
    )
  end

  defp found({:ok, id}), do: {:ok, id}
  defp found(:error), do: {:error, :not_found}

  ## Views

  defp page(rows, limit, field, view) do
    {rows, next} = Paging.page(rows, limit, field)
    names = names(rows)
    {:ok, %{entries: Enum.map(rows, &view.(&1, names)), next_cursor: next}}
  end

  defp names(members),
    do: members |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Accounts.short_names()

  @doc false
  # What the gym's staff see of a membership: no email, user id or profile.
  @spec staff_view(Member.t(), map()) :: map()
  def staff_view(%Member{} = member, names) do
    %{
      gym_member_id: member.id,
      status: member.status,
      name: get_in(names, [member.user_id, :short_name]),
      joined_via: member.joined_via,
      auto_approved: member.auto_approved,
      requested_at: member.requested_at,
      joined_at: member.activated_at,
      responded_at: member.responded_at,
      ended_at: member.ended_at,
      ended_reason: member.ended_reason
    }
  end

  @doc false
  # What a member sees of their own membership.
  @spec own_view(Member.t(), map()) :: map()
  def own_view(%Member{} = member, gyms) do
    %{
      gym_member_id: member.id,
      gym: %{gym_id: member.gym_id, name: Map.get(gyms, member.gym_id)},
      status: member.status,
      joined_via: member.joined_via,
      auto_approved: member.auto_approved,
      requested_at: member.requested_at,
      joined_at: member.activated_at,
      responded_at: member.responded_at,
      ended_at: member.ended_at,
      ended_reason: member.ended_reason
    }
  end

  defp gym_names(members) do
    Repo.all(
      from(g in Gym,
        where: g.id in ^Enum.map(members, & &1.gym_id),
        select: {g.id, g.name}
      ),
      @unlogged
    )
    |> Map.new()
  end

  defp settings_view(gym, settings, membership) do
    code =
      with %EnrollmentSettings{join_code_sealed: sealed} when is_binary(sealed) <- settings,
           {:ok, canonical} <- MemberSecrets.open_join_code(sealed) do
        MemberSecrets.display_join_code(canonical)
      else
        _ -> nil
      end

    %{
      gym_id: gym.id,
      join_code: code,
      join_code_rotated_at: code && settings.join_code_rotated_at,
      auto_approve: (settings && settings.auto_approve) || false,
      auto_approve_changed_at: settings && settings.auto_approve_changed_at,
      can_manage: match?({:ok, _}, Policy.check(membership, :manage_enrollment_settings))
    }
  end

  ## Limits

  defp join_limit(client_ip, user) do
    rules = [{"gym_join_client", key("client", client_ip), 20, 600}]

    rules =
      if user, do: rules ++ [{"gym_join_user", key("user", user.id), 10, 600}], else: rules

    RateLimit.hit(rules)
  end

  @doc false
  # Member administration (decisions, removals, settings, invitation resends
  # and cancellations): per user.
  @spec admin_limit(User.t()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def admin_limit(%User{id: user_id}),
    do: RateLimit.hit([{"gym_member_admin_user", key("user", user_id), 120, 600}])

  defp key(kind, value), do: MemberSecrets.rate_limit_key(kind, value)

  ## Telemetry

  # Outcomes only: never a code, a name or an id.
  defp emit(event, result) do
    outcome =
      case result do
        {:ok, outcome} when outcome in [:created, :existing] -> outcome
        {:ok, _} -> :ok
        {:error, %Changeset{}} -> :validation_error
        {:error, {:conflict, _}} -> :conflict
        {:error, {:rate_limited, _}} -> :rate_limited
        {:error, reason} when is_atom(reason) -> reason
      end

    :telemetry.execute([:simple_fit, :gyms, :member, event], %{count: 1}, %{outcome: outcome})
  end
end
