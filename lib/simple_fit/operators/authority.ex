defmodule SimpleFit.Operators.Authority do
  @moduledoc """
  The checks every operator request shares (SF-110, ADR 0028; extracted for the SF-111
  action framework, ADR 0029). Internal to `SimpleFit.Operators`. Each reads the
  database, with no cache:

      session → operator of that user, not suspended or revoked → active (keys
      enrolled) → an active grant of the permission → a key check in this session,
      fresh enough for the permission

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

  def check(%Operator{status: :pending_enrollment} = op, _session_id, _permission, _assurance),
    do: {:error, :enrollment_required, op}

  def check(%Operator{status: :active} = op, session_id, permission, assurance) do
    cond do
      not Policy.permission?(permission) or not granted?(op.id, permission) ->
        {:error, :forbidden, op}

      not step_up_satisfies?(
        op.id,
        session_id,
        strongest(Policy.assurance(permission), assurance)
      ) ->
        {:error, :step_up_required, op}

      true ->
        {:ok, %Principal{operator_id: op.id, user_id: op.user_id, session_id: session_id}}
    end
  end

  def check(%Operator{}, _session_id, _permission, _assurance), do: {:error, :not_found, nil}

  defp strongest(:fresh_key, _other), do: :fresh_key
  defp strongest(_one, :fresh_key), do: :fresh_key
  defp strongest(one, _other), do: one

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
        assurance == :key or
          DateTime.diff(DateTime.utc_now(), step_up.verified_at) <= Policy.fresh_window()
    end
  end

  @doc "An operator with its active permissions and key counts (the read projection)."
  @spec summary(Operator.t()) :: map()
  def summary(op) do
    %{
      operator: op,
      permissions: if(op.status == :revoked, do: [], else: active_permissions(op.id)),
      registered_keys: active_credential_count(op.id),
      required_keys: Policy.required_authenticators()
    }
  end
end
