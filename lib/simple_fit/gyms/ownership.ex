defmodule SimpleFit.Gyms.Ownership do
  @moduledoc """
  Ownership transfer, staff revocation and the account-deletion guard
  (ADR 0026; D-G04, D-G26). Internal to `SimpleFit.Gyms`.

  Both writes run in one transaction that locks the gym row first, then the
  staff memberships involved (`SimpleFit.Gyms.Access.authorize_locked/3`),
  so a transfer and a revocation at the same gym serialize: whichever commits
  second sees the first one's result. The partial unique index allows only
  one active owner at any moment, and the deferred constraint trigger rejects
  a commit that leaves a gym without one.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{Access, Audit, Gym, Policy, StaffInvitations, StaffMembership}
  alias SimpleFit.Repo

  @type previous_owner :: :stay_as_manager | :leave

  @doc """
  Commits an ownership transfer at a completed gym: the actor, its current
  owner, hands ownership to another active staff member of the same gym.
  The previous owner's membership ends (`transferred`); with
  `:stay_as_manager` they get a new `manager` membership.

  This is the commit step of D-G04. Requesting a transfer and the target's
  acceptance within 7 days belong to a dedicated ownership-transfer backend
  ticket, after SF-92 (ADR 0026, SF-83 amendment); no HTTP operation calls
  this yet, and production code must never call it without that acceptance.
  """
  @spec transfer(User.t(), term(), term(), previous_owner()) ::
          {:ok, %{owner: StaffMembership.t(), previous_owner: StaffMembership.t() | nil}}
          | {:error, :not_found | :forbidden | {:conflict, map()}}
  def transfer(%User{} = actor, gym_id, target_id, previous_owner)
      when previous_owner in [:stay_as_manager, :leave] do
    Repo.transaction(fn ->
      with {:ok, %{gym: gym, membership: owner}} <-
             Access.authorize_locked(actor, gym_id, :transfer_ownership),
           :ok <- completed(gym),
           %StaffMembership{} = target <- Access.lock_staff_membership(gym.id, target_id),
           :ok <- not_self(target, owner) do
        commit_transfer!(gym, owner, target, previous_owner, actor.id)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> tap(&emit(:transferred, &1))
  end

  @doc """
  Ends an active staff membership: another member's (`removed`) or the
  actor's own (`left`, SF-93). The owner may remove any manager, coach or
  front desk; a manager only a coach or front desk; other roles nobody.
  Managers, coaches and front desk may leave (`leave_gym`). Nobody removes
  the owner, and the owner never leaves: ownership moves only by a transfer
  (`409 conflict`, `staff_membership: owner_requires_transfer`). The ended
  user loses every permission at that gym on their next request, and the
  pending invitations their membership issued are cancelled in the same
  transaction (SF-93). Other gyms and the user's session are untouched.
  """
  @spec revoke(User.t(), term(), term()) ::
          {:ok, StaffMembership.t()} | {:error, :not_found | :forbidden | {:conflict, map()}}
  def revoke(%User{} = actor, gym_id, target_id) do
    Repo.transaction(fn ->
      with {:ok, %{gym: gym, membership: actor_membership}} <-
             Access.authorize_locked(actor, gym_id, :view_workspace),
           %StaffMembership{} = target <- Access.lock_staff_membership(gym.id, target_id),
           {:ok, reason} <- ending(target, actor_membership),
           :ok <- StaffInvitations.admin_limit(actor) do
        now = DateTime.utc_now()
        ended = end!(target, reason, now)
        StaffInvitations.cancel_issued_by!(target, nil, actor.id, now)

        Audit.record!(
          %{
            gym_id: gym.id,
            actor_user_id: actor.id,
            event_type: :staff_membership_ended,
            staff_membership_id: target.id,
            from_role: target.role,
            reason: reason
          },
          now
        )

        ended
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> tap(&emit(:revoked, &1))
  end

  @doc """
  The account-deletion guard (D-G26): `:ok`, or `409 conflict`
  (`gym_ownership: transfer_required`) while the user is the active owner of
  a completed gym. Read-only; see `SimpleFit.Gyms.check_account_deletion/1`
  for the contract of the future account-deletion workflow.
  """
  @spec check_account_deletion(User.t()) :: :ok | {:error, {:conflict, map()}}
  def check_account_deletion(%User{id: user_id}) when is_binary(user_id) do
    owns_completed? =
      Repo.exists?(
        from(m in StaffMembership,
          join: g in Gym,
          on: g.id == m.gym_id,
          where:
            m.user_id == ^user_id and m.role == :owner and m.status == :active and
              g.setup_status == :completed
        )
      )

    if owns_completed?,
      do: {:error, {:conflict, %{gym_ownership: "transfer_required"}}},
      else: :ok
  end

  # -- Transfer ----------------------------------------------------------------

  defp completed(%Gym{setup_status: :completed}), do: :ok
  defp completed(%Gym{}), do: {:error, {:conflict, %{setup_status: "draft"}}}

  defp not_self(%StaffMembership{id: id}, %StaffMembership{id: id}),
    do: {:error, {:conflict, %{staff_membership: "already_owner"}}}

  defp not_self(_target, _owner), do: :ok

  # The old owner row ends before the target is promoted: the partial unique
  # index never sees two active owners, even inside the transaction.
  defp commit_transfer!(gym, owner, target, previous_owner, actor_id) do
    now = DateTime.utc_now()
    %StaffMembership{} = end!(owner, :transferred, now)
    StaffInvitations.cancel_issued_by!(owner, nil, actor_id, now)
    promoted = target |> Changeset.change(role: :owner) |> Repo.update!()

    stayed =
      if previous_owner == :stay_as_manager do
        Repo.insert!(%StaffMembership{
          gym_id: gym.id,
          user_id: owner.user_id,
          role: :manager,
          status: :active
        })
      end

    record_transfer!(gym.id, actor_id, owner, target, stayed, now)
    %{owner: promoted, previous_owner: stayed}
  end

  defp record_transfer!(gym_id, actor_id, owner, target, stayed, now) do
    base = %{gym_id: gym_id, actor_user_id: actor_id}

    Audit.record!(
      Map.merge(base, %{
        event_type: :ownership_transferred,
        staff_membership_id: target.id,
        from_role: target.role,
        to_role: :owner
      }),
      now
    )

    Audit.record!(
      Map.merge(base, %{
        event_type: :staff_membership_ended,
        staff_membership_id: owner.id,
        from_role: :owner,
        reason: :transferred
      }),
      now
    )

    if stayed do
      Audit.record!(
        Map.merge(base, %{
          event_type: :staff_membership_created,
          staff_membership_id: stayed.id,
          to_role: :manager
        }),
        now
      )
    end
  end

  # -- Revocation --------------------------------------------------------------

  # The actor's own membership: leaving (never the owner).
  defp ending(%StaffMembership{id: id, role: :owner}, %StaffMembership{id: id}),
    do: {:error, {:conflict, %{staff_membership: "owner_requires_transfer"}}}

  defp ending(%StaffMembership{id: id}, %StaffMembership{id: id} = actor) do
    with {:ok, _scope} <- Policy.check(actor, :leave_gym), do: {:ok, :left}
  end

  defp ending(target, actor) do
    with {:ok, scope} <- Policy.check(actor, :remove_staff),
         :ok <- revocable(target, actor, scope),
         do: {:ok, :removed}
  end

  defp revocable(%StaffMembership{role: :owner}, _actor, _scope), do: {:error, :forbidden}
  defp revocable(_target, _actor, :all), do: :ok

  defp revocable(%StaffMembership{role: role}, _actor, :coach_and_front_desk)
       when role in [:coach, :front_desk],
       do: :ok

  defp revocable(_target, _actor, _scope), do: {:error, :forbidden}

  defp end!(membership, reason, now) do
    membership
    |> Changeset.change(status: :ended, ended_at: now, ended_reason: reason)
    |> Repo.update!()
  end

  # Outcomes only: never an id.
  defp emit(event, {:ok, _result}), do: execute(event, :ok)
  defp emit(event, {:error, {:conflict, _details}}), do: execute(event, :conflict)
  defp emit(event, {:error, reason}), do: execute(event, reason)

  defp execute(event, outcome),
    do: :telemetry.execute([:simple_fit, :gyms, :staff, event], %{count: 1}, %{outcome: outcome})
end
