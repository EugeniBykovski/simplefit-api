defmodule SimpleFit.Gyms.Staff do
  @moduledoc """
  A gym's staff roster and role changes (ADR 0026, D-G03, D-G04; SF-93).
  Internal to `SimpleFit.Gyms`. Removal and leaving are
  `SimpleFit.Gyms.Ownership.revoke/3`; invitations are
  `SimpleFit.Gyms.StaffInvitations`.

  ## Roster

  Every active staff member sees the active roster (`view_staff`): the
  membership id, role, when they joined and a short name ("Natalia W.", from
  the account name; never an email, a user id or any profile). Ended
  memberships are the owner's and managers' (`view_staff_records`). Nothing
  about another gym, a CoachProfile, a FighterProfile or a Coach–Fighter
  relationship is read or shown (D-G06): a gym coach is affiliated through
  the `coach` membership alone.

  ## Role changes

  Within the fixed matrix (`change_staff_role`): the owner changes any
  manager, coach or front desk to manager, coach or front desk; a manager
  only between coach and front desk. Nobody changes their own role, nobody
  becomes `owner` (a transfer, D-G04) and the owner's row never changes
  (`409`, `staff_membership: owner_requires_transfer`). The change locks the
  gym row, then the actor's and the target's memberships (the SF-83 order),
  so concurrent role changes, revocations and transfers serialize and each
  re-checks the actor's current role. Pending invitations the target can no
  longer issue under the new role are cancelled in the same transaction.
  The same role again changes nothing (no audit event).
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{Access, Audit, Policy, StaffInvitations, StaffMembership}
  alias SimpleFit.Repo

  @unlogged [log: false]
  @default_limit 50
  @max_limit 100

  @type page :: %{entries: [map()], next_cursor: String.t() | nil}

  @doc """
  The gym's staff, oldest membership first (params: `status` `active`
  (default) or `ended`, `limit`, `cursor`). Ended staff need
  `view_staff_records`.
  """
  @spec list(User.t(), term(), map()) ::
          {:ok, page()} | {:error, :not_found | :forbidden | Changeset.t()}
  def list(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym, membership: viewer}} <- Access.authorize(user, gym_id, :view_staff),
         {:ok, %{status: status, limit: limit, cursor: cursor}} <- list_params(params),
         :ok <- may_list(viewer, status) do
      rows =
        from(m in StaffMembership,
          where: m.gym_id == ^gym.id and m.status == ^status,
          order_by: [asc: m.inserted_at, asc: m.id],
          limit: ^(limit + 1)
        )
        |> seek(cursor)
        |> Repo.all(@unlogged)

      {rows, rest} = Enum.split(rows, limit)
      names = rows |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Accounts.short_names()

      {:ok,
       %{
         entries: Enum.map(rows, &view(&1, names, viewer)),
         next_cursor: if(rest == [], do: nil, else: encode_cursor(List.last(rows)))
       }}
    end
  end

  defp may_list(_viewer, :active), do: :ok

  defp may_list(viewer, :ended) do
    with {:ok, _scope} <- Policy.check(viewer, :view_staff_records), do: :ok
  end

  @doc """
  Changes another staff member's role (`attrs`: `"role"`, nothing else). See
  the moduledoc for who may change whom.
  """
  @spec change_role(User.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :forbidden
             | {:conflict, map()}
             | {:rate_limited, pos_integer()}
             | Changeset.t()}
  def change_role(%User{} = user, gym_id, membership_id, attrs) when is_map(attrs) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym, membership: actor, scope: scope}} <-
               Access.authorize_locked(user, gym_id, :change_staff_role),
             {:ok, role} <- role_param(attrs),
             %StaffMembership{} = target <- Access.lock_staff_membership(gym.id, membership_id),
             :ok <- changeable(target, actor, role, scope),
             :ok <- StaffInvitations.admin_limit(user) do
          changed = apply_change!(target, role, user.id)
          names = Accounts.short_names(Enum.reject([changed.user_id], &is_nil/1))
          view(changed, names, actor)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
    |> tap(&emit(:role_changed, &1))
  end

  defp changeable(%StaffMembership{role: :owner}, _actor, _role, _scope),
    do: {:error, {:conflict, %{staff_membership: "owner_requires_transfer"}}}

  defp changeable(%StaffMembership{id: id}, %StaffMembership{id: id}, _role, _scope),
    do: {:error, :forbidden}

  defp changeable(_target, _actor, _role, :all), do: :ok

  defp changeable(%StaffMembership{role: from}, _actor, to, :coach_and_front_desk)
       when from in [:coach, :front_desk] and to in [:coach, :front_desk],
       do: :ok

  defp changeable(_target, _actor, _role, _scope), do: {:error, :forbidden}

  defp apply_change!(%StaffMembership{role: role} = target, role, _actor_id), do: target

  defp apply_change!(target, role, actor_id) do
    now = DateTime.utc_now()

    changed =
      target
      |> Changeset.change(role: role, updated_at: now)
      |> Repo.update!(@unlogged)

    StaffInvitations.cancel_issued_by!(target, role, actor_id, now)

    Audit.record!(
      %{
        gym_id: target.gym_id,
        actor_user_id: actor_id,
        event_type: :staff_role_changed,
        staff_membership_id: target.id,
        from_role: target.role,
        to_role: role
      },
      now
    )

    changed
  end

  @roles ~w(manager coach front_desk)

  # Exactly `role`, one of the invitable roles: never `owner` (a transfer),
  # never another field (a user id, a status, a gym).
  defp role_param(attrs) do
    changeset =
      {%{}, %{role: :string}}
      |> Changeset.cast(attrs, [:role])
      |> Changeset.validate_required([:role])
      |> Changeset.validate_inclusion(:role, @roles)

    changeset =
      attrs
      |> Map.keys()
      |> Enum.reject(&(&1 == "role"))
      |> Enum.sort_by(&to_string/1)
      |> Enum.reduce(changeset, fn key, acc ->
        %{acc | errors: [{key, {"is not a permitted field", []}} | acc.errors], valid?: false}
      end)

    if changeset.valid?,
      do: {:ok, String.to_existing_atom(Changeset.get_field(changeset, :role))},
      else: {:error, changeset}
  end

  ## Views

  defp view(%StaffMembership{} = membership, names, viewer) do
    %{
      staff_membership_id: membership.id,
      role: membership.role,
      status: membership.status,
      name: get_in(names, [membership.user_id, :short_name]),
      is_viewer: membership.id == viewer.id,
      joined_at: membership.inserted_at,
      ended_at: membership.ended_at,
      ended_reason: membership.ended_reason
    }
  end

  ## Paging

  defp list_params(params) do
    types = %{status: :string, limit: :integer, cursor: :string}

    changeset =
      {%{status: "active", limit: @default_limit, cursor: nil}, types}
      |> Changeset.cast(Map.take(params, ["status", "limit", "cursor"]), Map.keys(types))
      |> Changeset.validate_inclusion(:status, ~w(active ended))
      |> Changeset.validate_number(:limit,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: @max_limit
      )

    with %Changeset{valid?: true} <- changeset,
         {:ok, position} <- decode_cursor(Changeset.get_field(changeset, :cursor)) do
      {:ok,
       %{
         status: String.to_existing_atom(Changeset.get_field(changeset, :status)),
         limit: Changeset.get_field(changeset, :limit),
         cursor: position
       }}
    else
      %Changeset{} = invalid ->
        {:error, invalid}

      :error ->
        {:error, Changeset.add_error(changeset, :cursor, "is invalid", validation: :format)}
    end
  end

  defp seek(query, nil), do: query

  defp seek(query, {at, id}),
    do: from(m in query, where: m.inserted_at > ^at or (m.inserted_at == ^at and m.id > ^id))

  defp encode_cursor(%StaffMembership{inserted_at: at, id: id}),
    do: Base.url_encode64("#{DateTime.to_unix(at, :microsecond)}|#{id}", padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [micros, id] <- String.split(decoded, "|"),
         {micros, ""} <- Integer.parse(micros),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :error
    end
  end

  # Outcomes only: never an id.
  defp emit(event, {:ok, _}), do: execute(event, :ok)
  defp emit(event, {:error, {:conflict, _}}), do: execute(event, :conflict)
  defp emit(event, {:error, {:rate_limited, _}}), do: execute(event, :rate_limited)
  defp emit(event, {:error, %Changeset{}}), do: execute(event, :validation_error)
  defp emit(event, {:error, reason}), do: execute(event, reason)

  defp execute(event, outcome),
    do: :telemetry.execute([:simple_fit, :gyms, :staff, event], %{count: 1}, %{outcome: outcome})
end
