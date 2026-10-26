defmodule SimpleFit.Gyms do
  @moduledoc """
  Gyms: the tenant, its staff (workspace) memberships and their permissions
  (ADR 0026; SF-83).

  A gym is the tenant root of everything gym-scoped. People work at a gym
  through a staff membership with one fixed role (`owner`, `manager`,
  `coach`, `front_desk`); a user may hold memberships at several gyms, each
  with its own role, and nothing about a gym is stored on the user (no role,
  type or "current gym"; ADR 0009). Exactly one active owner per gym is a
  database invariant (D-G04).

  ## Authorization (D-G15, D-G24)

  Every gym operation names the gym explicitly (the API path
  `/api/v1/gyms/{gym_id}/...`) and acts for the authenticated user. Access is
  re-derived on every call from that user's active staff membership at that
  gym and the fixed matrix in `SimpleFit.Gyms.Policy`:

    * unknown gym, malformed id, or no active membership there -> `:not_found`
      (outsiders never learn that a private gym exists);
    * active membership whose role lacks the permission -> `:forbidden`.

  Nothing else grants gym rights: not an account, a Coach or Fighter profile,
  a Coach–Fighter relationship, or a client-selected workspace. No gym
  permission reads a fighter's private training data (D-G06).

  ## Boundaries

  Creating a gym creates a draft and its owner membership only (D-G05). The
  setup steps, locations and completion (which requires a primary location)
  are SF-85's; entry projection (`GYM_WORKSPACE`) is SF-84's; staff roles,
  coach affiliation and invitations are SF-92's; participant memberships are
  later tickets. Ownership transfer and revocation exist here as domain
  operations only: the transfer request and acceptance (D-G04) need a
  dedicated backend ticket, and revocation's HTTP operation comes with SF-92.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{Access, Creation, Gym, GymLocation, Ownership, Policy, StaffMembership}
  alias SimpleFit.Repo

  @default_limit 50
  @max_limit 100

  @typedoc "A gym as one of its staff sees it, with that viewer's role and permissions."
  @type view :: map()

  @typedoc "A page of views and the cursor of the next one (`nil` on the last page)."
  @type page :: %{entries: [view()], next_cursor: String.t() | nil}

  ## Creation

  @doc """
  Creates a draft gym owned by `user` and its owner membership, atomically
  (`attrs`, string keys: `client_request_id`, `name`, `gym_type`; nothing
  else; the user's account registration must be complete). A replayed
  `client_request_id` returns the same gym (`:existing`); while the user has
  an open draft, any create returns it (`:resumed`). See
  `SimpleFit.Gyms.Creation` for idempotency, locking and abuse limits.
  """
  @spec create_gym(User.t(), map(), String.t()) ::
          {:ok, view(), Creation.outcome()}
          | {:error, Changeset.t() | {:conflict, map()} | {:rate_limited, pos_integer()}}
  def create_gym(%User{} = user, attrs, client_ip) do
    with {:ok, gym, membership, outcome} <- Creation.create(user, attrs, client_ip) do
      {:ok, view(gym, membership, locations(gym.id)), outcome}
    end
  end

  ## Reads

  @doc """
  The gyms where `user` holds an active staff membership, newest membership
  first (params: `limit` 1..100, default 50; `cursor` from the previous page).
  Only the user's own memberships are read.
  """
  @spec list_my_gyms(User.t(), map()) :: {:ok, page()} | {:error, Changeset.t()}
  def list_my_gyms(%User{id: user_id}, params) when is_binary(user_id) and is_map(params) do
    with {:ok, %{limit: limit, cursor: cursor}} <- page_params(params) do
      rows =
        from(m in StaffMembership,
          join: g in Gym,
          on: g.id == m.gym_id,
          where: m.user_id == ^user_id and m.status == :active,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^(limit + 1),
          select: {g, m}
        )
        |> seek(cursor)
        |> Repo.all(log: false)

      {rows, rest} = Enum.split(rows, limit)

      {:ok,
       %{
         entries: Enum.map(rows, fn {gym, membership} -> view(gym, membership, nil) end),
         next_cursor: if(rest == [], do: nil, else: rows |> List.last() |> encode_cursor())
       }}
    end
  end

  @doc "One gym, for one of its active staff (`:not_found` otherwise)."
  @spec get_gym(User.t(), term()) :: {:ok, view()} | {:error, :not_found}
  def get_gym(%User{} = user, gym_id) do
    with {:ok, %{gym: gym, membership: membership}} <-
           Access.authorize(user, gym_id, :view_workspace) do
      {:ok, view(gym, membership, locations(gym.id))}
    end
  end

  ## Authorization

  @doc """
  Whether `user` may perform `permission` at the gym `gym_id`: the gym, the
  user's active membership and the grant's scope, or `:not_found` /
  `:forbidden` (see the module documentation). Read-only; operations that
  change gym state use the locking variant inside their transaction.
  """
  @spec authorize(User.t(), term(), Policy.permission()) ::
          {:ok, Access.t()} | {:error, :not_found | :forbidden}
  defdelegate authorize(user, gym_id, permission), to: Access

  ## Ownership and staff

  @doc "See `SimpleFit.Gyms.Ownership.transfer/4`."
  @spec transfer_ownership(User.t(), term(), term(), Ownership.previous_owner()) ::
          {:ok, %{owner: StaffMembership.t(), previous_owner: StaffMembership.t() | nil}}
          | {:error, :not_found | :forbidden | {:conflict, map()}}
  defdelegate transfer_ownership(actor, gym_id, target_staff_membership_id, previous_owner),
    to: Ownership,
    as: :transfer

  @doc "See `SimpleFit.Gyms.Ownership.revoke/3`."
  @spec revoke_staff_membership(User.t(), term(), term()) ::
          {:ok, StaffMembership.t()} | {:error, :not_found | :forbidden | {:conflict, map()}}
  defdelegate revoke_staff_membership(actor, gym_id, staff_membership_id),
    to: Ownership,
    as: :revoke

  ## Account deletion

  @doc """
  The gym side of account deletion (D-G26): `:ok`, or `409 conflict`
  (`gym_ownership: transfer_required`) while the user is the active owner of
  a completed gym.

  Contract for the future account-deletion workflow (there is no
  account-deletion endpoint yet): inside its deletion transaction it must
  call this guard and stop on a conflict; then remove the user's draft gyms
  (D-G20) and end their other active staff memberships with reason
  `account_deleted`, through functions this context will add with that
  workflow. Until then the database itself refuses to delete a user who has
  any active staff membership (an active membership cannot lose its user),
  so no gym can be left without an owner; ended memberships keep their
  history with the user removed.
  """
  @spec check_account_deletion(User.t()) :: :ok | {:error, {:conflict, map()}}
  defdelegate check_account_deletion(user), to: Ownership

  ## Views

  defp view(gym, membership, locations) do
    base = %{
      id: gym.id,
      name: gym.name,
      gym_type: gym.gym_type,
      setup_status: gym.setup_status,
      inserted_at: gym.inserted_at,
      updated_at: gym.updated_at,
      viewer: %{
        staff_membership_id: membership.id,
        role: membership.role,
        permissions: Policy.permissions_of(membership.role)
      }
    }

    if locations, do: Map.put(base, :locations, Enum.map(locations, &location_view/1)), else: base
  end

  defp location_view(%GymLocation{} = location) do
    Map.take(location, [
      :id,
      :name,
      :country_code,
      :city,
      :address_line,
      :entrance_note,
      :is_primary
    ])
  end

  defp locations(gym_id) do
    Repo.all(
      from(l in GymLocation,
        where: l.gym_id == ^gym_id and is_nil(l.archived_at),
        order_by: [desc: l.is_primary, asc: l.inserted_at, asc: l.id]
      ),
      log: false
    )
  end

  ## Pages

  defp page_params(params) do
    types = %{limit: :integer, cursor: :string}

    changeset =
      {%{limit: @default_limit, cursor: nil}, types}
      |> Changeset.cast(params, Map.keys(types))
      |> Changeset.validate_number(:limit,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: @max_limit
      )

    with %Changeset{valid?: true} <- changeset,
         {:ok, position} <- decode_cursor(Changeset.get_field(changeset, :cursor)) do
      {:ok, %{limit: Changeset.get_field(changeset, :limit), cursor: position}}
    else
      %Changeset{} = invalid ->
        {:error, invalid}

      :error ->
        {:error, Changeset.add_error(changeset, :cursor, "is invalid", validation: :format)}
    end
  end

  defp seek(query, nil), do: query

  defp seek(query, {at, id}),
    do:
      from([m, _g] in query,
        where: m.inserted_at < ^at or (m.inserted_at == ^at and m.id < ^id)
      )

  defp encode_cursor({_gym, %StaffMembership{inserted_at: at, id: id}}),
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
end
