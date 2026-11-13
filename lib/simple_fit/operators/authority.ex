defmodule SimpleFit.Operators.Authority do
  @moduledoc """
  The checks every operator request shares (SF-110, ADR 0028; extracted for the SF-111
  action framework, ADR 0029). Internal to `SimpleFit.Operators`. Each reads the
  database, with no cache:

      session → operator of that user, not suspended or revoked → an active grant
      of the permission → the permission's assurance: `:session` is met by the
      session itself (any sign-in method, SF-157); `:fresh_key` needs an active
      operator (keys enrolled) with a fresh key check in this session

  The operator always comes from the session's user, never from the request.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Operators.{Credential, Grant, Operator, Policy, Principal, StepUp}
  alias SimpleFit.Repo

  @type refusal :: :not_found | :forbidden | :step_up_required | :enrollment_required

  @doc """
  Whether `operator` may use `permission` in `session_id` now, at `assurance` or the
  permission's own, whichever is stronger. The refusing operator comes back for the
  audit (`nil` when there is none to name).
  """
  @spec check(Operator.t() | nil, Ecto.UUID.t(), Policy.permission(), Policy.assurance() | nil) ::
          {:ok, Principal.t()} | {:error, refusal(), Operator.t() | nil}
  def check(operator, session_id, permission, assurance \\ nil)

  def check(nil, _session_id, _permission, _assurance), do: {:error, :not_found, nil}

  def check(%Operator{status: status} = op, session_id, permission, assurance)
      when status in [:pending_enrollment, :active] do
    cond do
      not Policy.permission?(permission) or not granted?(op.id, permission) ->
        {:error, :forbidden, op}

      strongest(Policy.assurance(permission), assurance) == :session ->
        {:ok, %Principal{operator_id: op.id, user_id: op.user_id, session_id: session_id}}

      # A key check needs keys: a pending operator registers them first.
      status == :pending_enrollment ->
        {:error, :enrollment_required, op}

      not step_up_satisfies?(op.id, session_id, :fresh_key) ->
        {:error, :step_up_required, op}

      true ->
        {:ok, %Principal{operator_id: op.id, user_id: op.user_id, session_id: session_id}}
    end
  end

  def check(%Operator{}, _session_id, _permission, _assurance), do: {:error, :not_found, nil}

  defp strongest(:fresh_key, _other), do: :fresh_key
  defp strongest(_one, :fresh_key), do: :fresh_key
  defp strongest(:session, _other), do: :session

  @doc "The user's operator if it can use operator endpoints at all: not suspended, not revoked."
  @spec usable_operator(Ecto.UUID.t()) :: Operator.t() | nil
  def usable_operator(user_id) do
    Repo.one(
      from(o in Operator,
        where: o.user_id == ^user_id and o.status in [:pending_enrollment, :active]
      ),
      log: false
    )
  end

  @doc "Locks operator rows `FOR UPDATE`, in id order (no deadlocks between two writers)."
  @spec lock_operators!([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => Operator.t()}
  def lock_operators!(ids) do
    from(o in Operator, where: o.id in ^ids, order_by: o.id, lock: "FOR UPDATE")
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc "Inside a transaction: holds the session, or rolls back with `:session_revoked`."
  @spec hold_session!(User.t(), Session.t()) :: :ok
  def hold_session!(user, session) do
    case Accounts.hold_active_session(user, session) do
      :ok -> :ok
      _revoked -> Repo.rollback(:session_revoked)
    end
  end

  @doc "Whether the operator holds an active grant of `permission`."
  @spec granted?(Ecto.UUID.t(), Policy.permission()) :: boolean()
  def granted?(operator_id, permission) do
    Repo.exists?(
      from(g in Grant,
        where:
          g.operator_id == ^operator_id and g.permission == ^permission and is_nil(g.revoked_at)
      )
    )
  end

  @doc "The operator's active permissions, sorted."
  @spec active_permissions(Ecto.UUID.t()) :: [Policy.permission()]
  def active_permissions(operator_id) do
    Repo.all(
      from(g in Grant,
        where: g.operator_id == ^operator_id and is_nil(g.revoked_at),
        order_by: g.permission,
        select: g.permission
      )
    )
  end

  @doc "How many unrevoked security keys the operator has."
  @spec active_credential_count(Ecto.UUID.t()) :: non_neg_integer()
  def active_credential_count(operator_id) do
    Repo.aggregate(
      from(c in Credential, where: c.operator_id == ^operator_id and is_nil(c.revoked_at)),
      :count
    )
  end

  @doc "This session's current key check, if any."
  @spec current_step_up(Ecto.UUID.t(), Ecto.UUID.t()) :: StepUp.t() | nil
  def current_step_up(operator_id, session_id) do
    now = DateTime.utc_now()

    Repo.one(
      from(s in StepUp,
        where:
          s.operator_id == ^operator_id and s.session_id == ^session_id and is_nil(s.revoked_at) and
            s.expires_at > ^now,
        order_by: [desc: s.verified_at],
        limit: 1
      )
    )
  end

  @doc "Whether this session's key check meets `assurance`."
  @spec step_up_satisfies?(Ecto.UUID.t(), Ecto.UUID.t(), Policy.assurance()) :: boolean()
  def step_up_satisfies?(operator_id, session_id, assurance) do
    case current_step_up(operator_id, session_id) do
      nil ->
        false

      step_up ->
        assurance == :session or
          DateTime.diff(DateTime.utc_now(), step_up.verified_at) <= Policy.fresh_window()
    end
  end

  @doc "An operator with its active permissions and key counts (the read projection)."
  @spec summary(Operator.t()) :: map()
  def summary(%Operator{} = op), do: [op] |> summaries() |> hd()

  @doc """
  The read projection of `ops` (SF-129), in one set of grouped queries whatever their
  number: each operator's active permissions with where each came from (who granted it,
  when, under which reason, or the bootstrap ceremony), unrevoked key count, the account's
  short name (first name and an initial, SF-123's rule; never a full name or an address)
  and when the operator last completed a key check. Nothing about keys beyond the count.
  """
  @spec summaries([Operator.t()]) :: [map()]
  def summaries([]), do: []

  def summaries(ops) when is_list(ops) do
    ids = Enum.map(ops, & &1.id)

    grants =
      from(g in Grant,
        where: g.operator_id in ^ids and is_nil(g.revoked_at),
        order_by: [asc: g.operator_id, asc: g.permission]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.operator_id)

    keys =
      from(c in Credential,
        where: c.operator_id in ^ids and is_nil(c.revoked_at),
        group_by: c.operator_id,
        select: {c.operator_id, count()}
      )
      |> Repo.all()
      |> Map.new()

    checks =
      from(s in StepUp,
        where: s.operator_id in ^ids,
        group_by: s.operator_id,
        select: {s.operator_id, max(s.verified_at)}
      )
      |> Repo.all()
      |> Map.new()

    names = Accounts.short_names(Enum.map(ops, & &1.user_id))

    Enum.map(ops, fn op ->
      active = if op.status == :revoked, do: [], else: Map.get(grants, op.id, [])

      %{
        operator: op,
        permissions: Enum.map(active, & &1.permission),
        grants: Enum.map(active, &grant_view/1),
        registered_keys: Map.get(keys, op.id, 0),
        required_keys: Policy.required_authenticators(),
        short_name: get_in(names, [op.user_id, :short_name]),
        last_key_check_at: Map.get(checks, op.id)
      }
    end)
  end

  defp grant_view(%Grant{} = g) do
    %{
      permission: g.permission,
      granted_at: g.granted_at,
      granted_by_operator_id: g.granted_by_operator_id,
      reason_code: g.reason_code,
      bootstrap: not is_nil(g.ceremony_id)
    }
  end
end
