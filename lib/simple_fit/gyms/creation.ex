defmodule SimpleFit.Gyms.Creation do
  @moduledoc """
  The gym creation and ownership bootstrap transaction (ADR 0026; D-G05,
  D-G25). Internal to `SimpleFit.Gyms`.

  One transaction, serialized per creator by a transaction-scoped advisory
  lock, in this order:

    1. **Replay.** A `client_request_id` the creator already used returns
       that gym unchanged (`:existing`), while the creator is still active
       staff there; otherwise `409 conflict` (`client_request_id: reused`).
    2. **Open draft.** While the creator has an open draft, any create
       resolves to it (`:resumed`); the request's fields are ignored.
    3. **Abuse limits (D-G25).** At most 5 creations per user and 20 per
       client in any rolling 24 hours (`SimpleFit.RateLimit.hit_rolling/2`,
       exact). Only steps that reach this point count, and a count commits
       only with the gym it allowed, so a replay, a resumed draft or a
       refused attempt is never counted.
    4. **Insert.** The draft gym, its owner's staff membership and the audit
       events `gym_created` and `staff_membership_created` commit together;
       the database checks at commit that the gym has exactly one active
       owner.

  The client key is `SimpleFitWeb.ClientIP.limit_key/1`. Production refuses
  to boot without an explicit `TRUSTED_PROXY_HOPS`, so the proxy topology is
  always declared and the per-client limit is never silently shared by every
  client behind an unconfigured proxy.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Plug.Crypto.KeyGenerator
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{Audit, Gym, StaffMembership}
  alias SimpleFit.{RateLimit, Repo}

  @create_keys ~w(client_request_id name gym_type)

  @user_limit 5
  @client_limit 20
  @window 86_400

  @rate_limit_salt "simplefit gyms rate limit v1"

  @type outcome :: :created | :existing | :resumed

  @doc """
  Creates a draft gym owned by `user` (`attrs`, string keys:
  `client_request_id`, `name`, `gym_type`; nothing else), or returns the
  existing one for a replayed key or an open draft. `client_ip` is the
  client's rate-limit key.
  """
  @spec create(User.t(), map(), String.t()) ::
          {:ok, Gym.t(), StaffMembership.t(), outcome()}
          | {:error, Changeset.t() | {:conflict, map()} | {:rate_limited, pos_integer()}}
  def create(%User{id: user_id} = user, attrs, client_ip)
      when is_binary(user_id) and is_map(attrs) and is_binary(client_ip) do
    with {:ok, request} <- request(user, attrs) do
      Repo.transaction(fn -> create_locked(user_id, request, client_ip) end, log: false)
      |> case do
        {:ok, {gym, membership, outcome}} ->
          emit(outcome)
          {:ok, gym, membership, outcome}

        {:error, reason} ->
          emit(reason_tag(reason))
          {:error, reason}
      end
    end
  end

  defp create_locked(user_id, request, client_ip) do
    lock_creator!(user_id)

    case by_request(user_id, request.client_request_id) do
      %Gym{} = gym ->
        replay(gym, user_id)

      nil ->
        case open_draft(user_id) do
          {%Gym{} = gym, %StaffMembership{} = membership} -> {gym, membership, :resumed}
          nil -> limit_then_insert(user_id, request, client_ip)
        end
    end
  end

  defp replay(gym, user_id) do
    case active_membership(gym.id, user_id) do
      %StaffMembership{} = membership -> {gym, membership, :existing}
      nil -> Repo.rollback({:conflict, %{client_request_id: "reused"}})
    end
  end

  defp limit_then_insert(user_id, request, client_ip) do
    case RateLimit.hit_rolling([
           {"gym_create_user", key("user", user_id), @user_limit, @window},
           {"gym_create_client", key("client", client_ip), @client_limit, @window}
         ]) do
      :ok -> insert!(user_id, request)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert!(user_id, request) do
    now = DateTime.utc_now()

    gym =
      case Repo.insert(request.changeset, log: false) do
        {:ok, gym} -> gym
        {:error, changeset} -> Repo.rollback(changeset)
      end

    membership =
      Repo.insert!(%StaffMembership{
        gym_id: gym.id,
        user_id: user_id,
        role: :owner,
        status: :active
      })

    Audit.record!(%{gym_id: gym.id, actor_user_id: user_id, event_type: :gym_created}, now)

    Audit.record!(
      %{
        gym_id: gym.id,
        actor_user_id: user_id,
        event_type: :staff_membership_created,
        staff_membership_id: membership.id,
        to_role: :owner
      },
      now
    )

    {gym, membership, :created}
  end

  # -- Request -----------------------------------------------------------------

  defp request(user, attrs) do
    id_changeset =
      {%{}, %{client_request_id: Ecto.UUID}}
      |> Changeset.cast(attrs, [:client_request_id])
      |> Changeset.validate_required([:client_request_id])

    client_request_id = Changeset.get_field(id_changeset, :client_request_id)

    gym_changeset =
      user.id
      |> Gym.create_changeset(client_request_id, attrs)
      |> merge_errors(id_changeset)
      |> reject_unknown_keys(attrs)
      |> require_account_registration(user)

    if gym_changeset.valid?,
      do: {:ok, %{client_request_id: client_request_id, changeset: gym_changeset}},
      else: {:error, gym_changeset}
  end

  defp merge_errors(changeset, %Changeset{errors: []}), do: changeset

  defp merge_errors(changeset, %Changeset{errors: errors}),
    do: %{changeset | errors: errors ++ changeset.errors, valid?: false}

  # Owners, roles, statuses and ids are never accepted from clients.
  defp reject_unknown_keys(changeset, attrs) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in @create_keys))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a field of a gym", []}} | acc.errors], valid?: false}
    end)
  end

  # A gym is created by a user with completed account registration (ADR 0016,
  # D-G05); no other capability is needed, and none is granted beforehand.
  defp require_account_registration(changeset, user) do
    if Accounts.registration_complete?(user),
      do: changeset,
      else:
        Changeset.add_error(changeset, :account_registration, "must be completed first",
          validation: :required
        )
  end

  # -- Queries -----------------------------------------------------------------

  defp lock_creator!(user_id) do
    %Postgrex.Result{} =
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "simplefit:gyms:create:" <> user_id
      ])

    :ok
  end

  defp by_request(user_id, client_request_id) do
    Repo.one(
      from(g in Gym,
        where: g.created_by_user_id == ^user_id and g.client_request_id == ^client_request_id
      ),
      log: false
    )
  end

  defp open_draft(user_id) do
    Repo.one(
      from(g in Gym,
        join: m in StaffMembership,
        on: m.gym_id == g.id and m.user_id == ^user_id and m.status == :active,
        where: g.created_by_user_id == ^user_id and g.setup_status == :draft,
        select: {g, m}
      ),
      log: false
    )
  end

  defp active_membership(gym_id, user_id) do
    Repo.one(
      from(m in StaffMembership,
        where: m.gym_id == ^gym_id and m.user_id == ^user_id and m.status == :active
      )
    )
  end

  # -- Limits ------------------------------------------------------------------

  defp key(kind, value),
    do: :crypto.mac(:hmac, :sha256, derived_key(), kind <> <<0>> <> value)

  defp derived_key do
    KeyGenerator.generate(secret_key_base(), @rate_limit_salt,
      length: 32,
      digest: :sha256,
      cache: Plug.Crypto.Keys
    )
  end

  defp secret_key_base do
    case Application.get_env(:simple_fit, SimpleFit.Gyms, [])[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 64 ->
        secret

      _missing ->
        raise ArgumentError,
              "SimpleFit.Gyms: secret_key_base must be at least 64 bytes (SECRET_KEY_BASE)"
    end
  end

  # -- Telemetry ---------------------------------------------------------------

  defp reason_tag(%Changeset{}), do: :invalid
  defp reason_tag({:conflict, _details}), do: :conflict
  defp reason_tag({:rate_limited, _retry_after}), do: :rate_limited

  # Outcomes only: never a name, id or key.
  defp emit(outcome),
    do: :telemetry.execute([:simple_fit, :gyms, :gym, :create], %{count: 1}, %{outcome: outcome})
end
