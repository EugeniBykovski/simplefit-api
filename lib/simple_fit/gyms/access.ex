defmodule SimpleFit.Gyms.Access do
  @moduledoc """
  Tenant resolution for gym operations (ADR 0026, D-G15, D-G24). Internal to
  `SimpleFit.Gyms`.

  The gym comes only from the id the caller names (the API path); the actor
  only from the authenticated session. Access is the actor's **active**
  staff membership at that gym, read from the database on every call (no
  cached role, no selected-workspace state), so a revocation applies to the
  next request.

    * no such gym, a malformed id, or no active membership there:
      `{:error, :not_found}` (a private gym's existence is never revealed);
    * an active membership whose role lacks the permission:
      `{:error, :forbidden}`.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{Gym, Policy, StaffMembership}
  alias SimpleFit.Repo

  @type t :: %{gym: Gym.t(), membership: StaffMembership.t(), scope: Policy.scope()}

  @doc "Read access: the gym, the actor's membership and the permission's scope."
  @spec authorize(User.t(), term(), Policy.permission()) ::
          {:ok, t()} | {:error, :not_found | :forbidden}
  def authorize(%User{id: user_id}, gym_id, permission) when is_binary(user_id) do
    with {:ok, gym_id} <- cast_id(gym_id),
         {%Gym{} = gym, %StaffMembership{} = membership} <- active(gym_id, user_id) do
      grant(gym, membership, permission)
    else
      _ -> denied(:not_found)
    end
  end

  @doc """
  Write access inside a transaction: locks the gym row (`FOR UPDATE`), then
  the actor's active membership (`FOR UPDATE`). Every operation that changes
  ownership or staff takes this lock order, so they serialize per gym.
  """
  @spec authorize_locked(User.t(), term(), Policy.permission()) ::
          {:ok, t()} | {:error, :not_found | :forbidden}
  def authorize_locked(%User{id: user_id}, gym_id, permission) when is_binary(user_id) do
    true = Repo.in_transaction?()

    with {:ok, gym_id} <- cast_id(gym_id),
         %Gym{} = gym <- lock_gym(gym_id),
         %StaffMembership{} = membership <- lock_active(gym.id, user_id) do
      grant(gym, membership, permission)
    else
      _ -> denied(:not_found)
    end
  end

  @doc """
  The actor's active membership at `gym_id` with its gym, inside the caller's
  transaction, share-locked (no permission check): `{:ok, %{gym, membership}}`
  or `{:error, :not_found}`.

  It takes the same lock order as every gym write (`authorize_locked/3`): the
  gym row first (`FOR SHARE`, its own statement), then the membership (`FOR
  SHARE`). A writer holding the gym row (revocation, transfer) therefore
  finishes first or waits; the two never wait on each other's rows in
  opposite order. (Locking the membership first deadlocked against a
  revocation once the caller wrote a row referencing the gym, SF-84.)
  """
  @spec lock_shared(User.t(), term()) ::
          {:ok, %{gym: Gym.t(), membership: StaffMembership.t()}} | {:error, :not_found}
  def lock_shared(%User{id: user_id}, gym_id) when is_binary(user_id) do
    true = Repo.in_transaction?()

    with {:ok, gym_id} <- cast_id(gym_id),
         %Gym{} = gym <-
           Repo.one(from(g in Gym, where: g.id == ^gym_id, lock: "FOR SHARE"), log: false),
         %StaffMembership{} = membership <-
           Repo.one(
             from(m in StaffMembership,
               where: m.gym_id == ^gym.id and m.user_id == ^user_id and m.status == :active,
               lock: "FOR SHARE"
             )
           ) do
      {:ok, %{gym: gym, membership: membership}}
    else
      _ -> denied(:not_found)
    end
  end

  @doc "Locks an active membership of `gym_id` by its id (`nil` if none)."
  @spec lock_staff_membership(Ecto.UUID.t(), term()) :: StaffMembership.t() | nil
  def lock_staff_membership(gym_id, membership_id) do
    case cast_id(membership_id) do
      {:ok, id} ->
        Repo.one(
          from(m in StaffMembership,
            where: m.id == ^id and m.gym_id == ^gym_id and m.status == :active,
            lock: "FOR UPDATE"
          )
        )

      :error ->
        nil
    end
  end

  @doc "Casts an id from a path or body; anything else is `:error`."
  @spec cast_id(term()) :: {:ok, Ecto.UUID.t()} | :error
  def cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  def cast_id(_id), do: :error

  defp grant(gym, membership, permission) do
    case Policy.check(membership, permission) do
      {:ok, scope} -> {:ok, %{gym: gym, membership: membership, scope: scope}}
      {:error, :forbidden} -> denied(:forbidden)
    end
  end

  defp active(gym_id, user_id) do
    Repo.one(
      from(g in Gym,
        join: m in StaffMembership,
        on: m.gym_id == g.id and m.user_id == ^user_id and m.status == :active,
        where: g.id == ^gym_id,
        select: {g, m}
      ),
      log: false
    )
  end

  defp lock_gym(gym_id),
    do: Repo.one(from(g in Gym, where: g.id == ^gym_id, lock: "FOR UPDATE"), log: false)

  defp lock_active(gym_id, user_id) do
    Repo.one(
      from(m in StaffMembership,
        where: m.gym_id == ^gym_id and m.user_id == ^user_id and m.status == :active,
        lock: "FOR UPDATE"
      )
    )
  end

  # Denials are counted (cross-gym probing shows as a rising `not_found`),
  # never with an id.
  defp denied(reason) do
    :telemetry.execute([:simple_fit, :gyms, :access, :denied], %{count: 1}, %{reason: reason})
    {:error, reason}
  end
end
