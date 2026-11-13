defmodule SimpleFit.Operators.Actions do
  @moduledoc """
  The admin action pipeline (SF-111, ADR 0029). Internal to `SimpleFit.Operators`;
  only actions declared in `SimpleFit.Operators.OperatorActions` exist.

  **Execute**, in one transaction:

      session held → the viewer's own operator (from the session, never the body),
      locked with the target in id order → permission and key check, asked again
      under the locks → target resolved, never the actor → operation id: a repeat of
      the same request returns the current state and changes nothing → expected
      revision → one-time confirmation consumed (when the action requires one) →
      plan computed again → domain change → operation recorded → audit event

  The allowed audit event is written in the same transaction: if it can't be
  written, nothing commits. Every other attempt by an identified operator ends in
  exactly one audit event of its own (`refused`, `conflict`, `invalid` or `failed`,
  with a `result_code`), written after the rollback and rate limited per operator so
  it can't be used to fill the table. Accounts without a usable operator get
  `:not_found` and leave no audit row (they aren't operators; SF-110 concealment).

  **Preview** reads only: the same authorization, target and plan, and for actions
  that require it a confirmation bound to the operator, the session, the action, the
  target, a digest of the canonical parameters (reason included) and the current
  revision, valid for `Policy.confirmation_ttl/0` seconds, usable once. A preview
  authorizes nothing later: execution checks everything again. Previews send no
  email, enqueue no job and call no provider. Refused previews are audited; allowed
  ones and their confirmations are recorded only in the confirmations table.

  Telemetry (`[:simple_fit, :admin_action, event]`) carries the action id, the phase
  and a result code: never a user, operator, target or session id, a reason or a token.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]
  import SimpleFit.Operators.Authority

  require Logger

  alias SimpleFit.Accounts.{Session, User}

  alias SimpleFit.Operators.{
    Action,
    Audit,
    ConfigurationActions,
    Confirmation,
    Operation,
    OperatorActions,
    OperatorTarget,
    UserActions
  }

  alias SimpleFit.Operators.{Policy, Redaction}
  alias SimpleFit.{RateLimit, Repo}
  alias SimpleFit.Sponsors.{ProposalReviewActions, ReviewActions}

  @token_prefix "sfc_"
  @token_bytes 32

  @type ctx :: %{optional(:request_id) => String.t() | nil}

  @doc "The declared action with this id."
  @spec fetch!(String.t()) :: Action.t()
  def fetch!(id), do: Enum.find(definitions(), &(&1.id == id)) || raise(ArgumentError)

  @doc "Every declared action id."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(definitions(), & &1.id)

  # Operator administration (SF-111), sponsor application review (SF-114), user
  # accounts (SF-122) and runtime flags (SF-128).
  defp definitions,
    do:
      OperatorActions.definitions() ++
        ReviewActions.definitions() ++
        ProposalReviewActions.definitions() ++
        UserActions.definitions() ++ ConfigurationActions.definitions()

  ## Preview

  @doc """
  Previews `action_id` on `target_id`: current and proposed state, impact, what it
  needs, and a one-time confirmation when the action requires one.
  """
  @spec preview(String.t(), User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def preview(action_id, %User{} = user, %Session{} = session, target_id, params, ctx \\ %{}) do
    action = fetch!(action_id)
    emit(:started, action, :preview)

    with {:ok, actor} <- concealed(user),
         :ok <- authorize_now(actor, session, action),
         {:ok, attrs} <- cast_request(action, params, :preview),
         {:ok, target} <- resolve(action, target_id),
         :ok <- not_self(action, actor, target),
         :ok <- revision(target, attrs[:expected_revision]),
         {:ok, plan} <- action.plan.(actor, target, attrs),
         :ok <- limit("operator_action_preview", user.id, Policy.preview_limit()) do
      emit(:previewed, action, :preview)
      {:ok, preview_view(action, actor, session, target, attrs, plan)}
    else
      {:error, reason} = error ->
        record_failure(action, user, session, target_id, :preview, reason, ctx)
        public(error)
    end
  end

  defp preview_view(action, actor, session, target, attrs, plan) do
    %{
      action: action.id,
      target: %{type: action.target_type, id: target.id, status: action.target.status(target)},
      expected_revision: target.revision,
      current_state: plan.from_state,
      proposed_state: plan.to_state,
      permission: Map.get(plan, :permission),
      impact: plan.impact,
      required_permission: action.permission,
      required_assurance: Atom.to_string(action.assurance),
      reason_code: attrs.reason_code,
      confirmation: confirmation(action, actor, session, target, attrs)
    }
  end

  defp confirmation(%Action{confirmation: :none}, _actor, _session, _target, _attrs),
    do: %{required: false, token: nil, expires_at: nil}

  defp confirmation(action, actor, session, target, attrs) do
    token =
      @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    now = DateTime.utc_now()
    expires_at = DateTime.add(now, Policy.confirmation_ttl())

    Repo.insert!(%Confirmation{
      token_sha256: :crypto.hash(:sha256, token),
      operator_id: actor.id,
      session_id: session.id,
      action: action.id,
      target_type: action.target_type,
      target_id: target.id,
      params_sha256: digest(action, target.id, target.revision, attrs),
      expected_revision: target.revision,
      expires_at: expires_at,
      inserted_at: now
    })

    %{required: true, token: token, expires_at: expires_at}
  end

  ## Execute

  @doc "Executes `action_id` on `target_id` (see the moduledoc). Returns the target's summary."
  @spec execute(String.t(), User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def execute(action_id, %User{} = user, %Session{} = session, target_id, params, ctx \\ %{}) do
    action = fetch!(action_id)
    emit(:started, action, :execute)

    with {:ok, actor} <- concealed(user),
         :ok <- authorize_now(actor, session, action),
         {:ok, attrs} <- cast_request(action, params, :execute),
         {:ok, target_id} <- uuid(target_id) do
      run(action, user, session, target_id, attrs, ctx)
    else
      {:error, reason} = error ->
        record_failure(action, user, session, target_id, :execute, reason, ctx)
        public(error)
    end
  end

  defp run(action, user, session, target_id, attrs, ctx) do
    request_digest = digest(action, target_id, attrs.expected_revision, attrs)

    try do
      Repo.transaction(fn ->
        transact(action, user, session, target_id, attrs, request_digest, ctx)
      end)
    rescue
      exception in [
        Postgrex.Error,
        Ecto.ConstraintError,
        Ecto.InvalidChangesetError,
        Ecto.StaleEntryError,
        DBConnection.ConnectionError
      ] ->
        Logger.error("admin action failed: #{action.id} (#{inspect(exception.__struct__)})")
        {:error, :action_failed}
    end
    |> case do
      {:error, {:replayed, target_id}} ->
        emit(:replayed, action, :execute)
        {:ok, action.target.project(action.target.fetch(target_id))}

      {:ok, summary} ->
        emit(:committed, action, :execute)
        emit(:audit_persisted, action, :execute, "allowed")
        {:ok, summary}

      {:error, reason} = error ->
        record_failure(action, user, session, target_id, :execute, reason, ctx)
        public(error)
    end
  end

  defp transact(action, user, session, target_id, attrs, request_digest, ctx) do
    {actor, target} = locked_parties!(action, user, session, target_id)
    replay!(attrs.operation_id, actor.id, action, request_digest, target.id)
    current!(target, attrs.expected_revision)
    confirmation_id = consume!(action, attrs, actor, session, target, request_digest)
    plan = plan!(action, actor, target, attrs)
    _ = action.apply.(actor, target, attrs, DateTime.utc_now(), plan)
    record_operation!(attrs.operation_id, actor.id, action.id, target.id, request_digest)
    updated = action.target.fetch(target.id)

    Audit.record!(
      %{
        action: action.event,
        command: action.id,
        outcome: :allowed,
        actor_operator_id: actor.id,
        actor_user_id: actor.user_id,
        permission: Map.get(plan, :permission) || action.permission,
        target_type: action.target_type,
        target_id: target.id,
        reason_code: attrs.reason_code,
        from_state: plan.from_state,
        to_state: plan.to_state,
        revision: updated.revision,
        confirmation_id: confirmation_id
      },
      Map.merge(ctx, %{session_id: session.id, operation_id: attrs.operation_id})
    )

    action.target.project(updated)
  end

  # Holds the session, locks the actor and the target (operators in id order, any
  # other target after the actor), authorizes again under the locks and resolves the
  # target, of which the actor is never a party.
  defp locked_parties!(action, user, session, target_id) do
    hold_session!(user, session)
    actor_id = (usable_operator(user.id) || Repo.rollback(:not_found)).id
    {actor, target} = lock_both!(action.target, actor_id, target_id)

    case check(actor, session.id, action.permission, action.assurance) do
      {:ok, _principal} -> emit(:authorized, action, :execute)
      {:error, reason, _op} -> Repo.rollback(reason)
    end

    target = target || Repo.rollback(:target_not_found)
    if action.target.party?(target, actor), do: Repo.rollback({:conflict, %{target: "self"}})
    {actor, target}
  end

  defp lock_both!(OperatorTarget, actor_id, target_id) do
    locked = lock_operators!(Enum.uniq([actor_id, target_id]))
    {Map.fetch!(locked, actor_id), Map.get(locked, target_id)}
  end

  defp lock_both!(target_module, actor_id, target_id) do
    actor = lock_operators!([actor_id]) |> Map.fetch!(actor_id)
    {actor, target_module.lock!(target_id)}
  end

  defp current!(%{revision: revision}, revision), do: :ok
  defp current!(%{revision: current}, _expected), do: Repo.rollback({:revision_conflict, current})

  defp plan!(action, actor, target, attrs) do
    case action.plan.(actor, target, attrs) do
      {:ok, plan} -> plan
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A repeat of the same request (same actor, action, target and digest) answers with
  # the current state and changes nothing; the id used for anything else is refused.
  defp replay!(operation_id, actor_id, %Action{id: action_id}, request_digest, target_id) do
    case Repo.get(Operation, operation_id) do
      nil ->
        :ok

      %Operation{
        actor_operator_id: ^actor_id,
        action: ^action_id,
        target_id: ^target_id,
        request_sha256: ^request_digest
      } ->
        Repo.rollback({:replayed, target_id})

      _other ->
        Repo.rollback({:conflict, %{operation_id: "reused"}})
    end
  end

  defp record_operation!(operation_id, actor_id, action_id, target_id, request_digest) do
    %Operation{
      id: operation_id,
      actor_operator_id: actor_id,
      action: action_id,
      target_id: target_id,
      request_sha256: request_digest
    }
    |> change(%{})
    |> unique_constraint(:id, name: :operator_operations_pkey)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> Repo.rollback({:conflict, %{operation_id: "concurrent"}})
    end
  end

  defp consume!(%Action{confirmation: :none}, _attrs, _actor, _session, _target, _digest), do: nil

  defp consume!(action, attrs, actor, session, target, request_digest) do
    token = attrs[:confirmation_token] || Repo.rollback(:confirmation_required)

    binding = [
      operator_id: actor.id,
      session_id: session.id,
      action: action.id,
      target_id: target.id,
      params_sha256: request_digest,
      expected_revision: attrs.expected_revision
    ]

    with {:ok, hash} <- token_hash(token),
         {1, [id]} <- consume_matching(hash, binding) do
      emit(:confirmed, action, :execute)
      id
    else
      _invalid -> Repo.rollback(:confirmation_invalid)
    end
  end

  # Consumes the confirmation only if every binding matches and it is unused and unexpired.
  defp consume_matching(hash, binding) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(c in Confirmation,
        where: c.token_sha256 == ^hash and is_nil(c.consumed_at) and c.expires_at > ^now,
        where: ^binding,
        select: c.id
      ),
      set: [consumed_at: now]
    )
  end

  defp token_hash(@token_prefix <> encoded = token) when byte_size(encoded) == 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, <<_::binary-size(@token_bytes)>>} -> {:ok, :crypto.hash(:sha256, token)}
      _ -> :error
    end
  end

  defp token_hash(_token), do: :error

  ## Shared steps

  defp concealed(%User{id: id}) do
    case usable_operator(id) do
      nil -> {:error, :not_found}
      op -> {:ok, op}
    end
  end

  defp authorize_now(actor, session, action) do
    case check(actor, session.id, action.permission, action.assurance) do
      {:ok, _principal} -> :ok
      {:error, reason, _op} -> {:error, reason}
    end
  end

  defp resolve(%Action{target: target_module}, target_id) do
    with {:ok, id} <- uuid(target_id),
         %{} = target <- target_module.fetch(id) do
      {:ok, target}
    else
      _ -> {:error, :target_not_found}
    end
  end

  defp not_self(action, actor, target),
    do:
      if(action.target.party?(target, actor),
        do: {:error, {:conflict, %{target: "self"}}},
        else: :ok
      )

  defp revision(_target, nil), do: :ok
  defp revision(%{revision: revision}, revision), do: :ok
  defp revision(%{revision: current}, _expected), do: {:error, {:revision_conflict, current}}

  # The canonical request: everything a confirmation and an operation id stand for.
  # Not the operation id (idempotency is separate) and not the token.
  defp digest(action, target_id, revision, attrs) do
    own =
      action.params
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&[Atom.to_string(&1), Map.fetch!(attrs, &1)])

    :crypto.hash(
      :sha256,
      Jason.encode!(["sf111.v1", action.id, target_id, revision, attrs.reason_code, own])
    )
  end

  defp cast_request(action, params, phase) do
    common =
      case phase do
        :preview ->
          %{reason_code: :string, expected_revision: :integer}

        :execute ->
          %{
            reason_code: :string,
            expected_revision: :integer,
            operation_id: Ecto.UUID,
            confirmation_token: :string
          }
      end

    types = Map.merge(common, action.params)

    required =
      Map.keys(action.params) ++
        [:reason_code] ++ if(phase == :execute, do: [:expected_revision, :operation_id], else: [])

    {%{}, types}
    |> cast(params, Map.keys(types))
    |> validate_required(required)
    |> validate_inclusion(:reason_code, action.reasons)
    |> validate_number(:expected_revision, greater_than_or_equal_to: 1)
    |> then(
      &if(phase == :execute, do: validate_length(&1, :confirmation_token, max: 100), else: &1)
    )
    |> action.validate.()
    |> apply_action(:validate)
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :target_not_found}
    end
  end

  defp limit(bucket, user_id, count) do
    RateLimit.hit([{bucket, :crypto.hash(:sha256, user_id), count, 3600}])
  end

  ## Errors, audit and telemetry of attempts that didn't succeed

  # The client sees SF-110's codes (an unknown target is `not_found` like any other) and
  # only documented, allowlisted details.
  defp public({:error, :target_not_found}), do: {:error, :not_found}

  defp public({:error, {:revision_conflict, current}}),
    do: {:error, {:revision_conflict, %{current_revision: current}}}

  defp public({:error, {:conflict, details}}),
    do: {:error, {:conflict, Redaction.details(details)}}

  defp public(error), do: error

  @refusals %{
    forbidden: "forbidden",
    step_up_required: "step_up_required",
    enrollment_required: "enrollment_required",
    target_not_found: "target_not_found",
    not_found: "operator_unavailable",
    session_revoked: "session_revoked",
    confirmation_required: "confirmation_required"
  }

  @doc false
  # Maps a failure to its audit outcome and result code.
  @spec classify(term()) :: {atom(), String.t()} | :skip
  def classify({:replayed, _}), do: :skip

  def classify(reason) when is_map_key(@refusals, reason),
    do: {:refused, Map.fetch!(@refusals, reason)}

  def classify({:conflict, %{target: "self"}}), do: {:refused, "self_action"}
  def classify({:rate_limited, _}), do: {:refused, "rate_limited"}
  def classify({:revision_conflict, _}), do: {:conflict, "revision_stale"}
  def classify({:conflict, details}) when is_map(details), do: {:conflict, conflict_code(details)}
  def classify(:confirmation_invalid), do: {:invalid, "confirmation_invalid"}
  def classify(%Ecto.Changeset{}), do: {:invalid, "validation_failed"}
  def classify(:action_failed), do: {:failed, "mutation_failed"}
  def classify(_other), do: {:failed, "unexpected"}

  defp conflict_code(details) do
    case Enum.sort(Map.to_list(details)) do
      [{key, value} | _] when is_binary(value) -> String.slice("#{key}_#{value}", 0, 59)
      _ -> "state_conflict"
    end
  end

  defp record_failure(action, user, session, target_id, phase, reason, ctx) do
    case {classify(reason), usable_operator(user.id)} do
      {:skip, _} ->
        :ok

      {{outcome, code}, actor} ->
        emit(telemetry_event(outcome), action, phase, code)

        # Only an operator's attempts are audited: a non-operator leaves no row.

        if actor && audit_failure?(phase, outcome),
          do: audit_failure(action, actor, session, target_id, outcome, code, ctx)
    end
  end

  # Previews only change something in the confirmations table, so only their refusals
  # are security evidence; every execution attempt is.
  defp audit_failure?(:preview, outcome), do: outcome == :refused
  defp audit_failure?(:execute, _outcome), do: true

  defp audit_failure(action, actor, session, target_id, outcome, code, ctx) do
    case limit("operator_refusal_audit", actor.user_id, Policy.refusal_audit_limit()) do
      :ok ->
        Audit.record!(
          %{
            action: action.id,
            command: action.id,
            outcome: outcome,
            result_code: code,
            actor_operator_id: actor.id,
            actor_user_id: actor.user_id,
            permission: action.permission,
            target_type: action.target_type,
            target_id: valid_uuid(target_id)
          },
          Map.put(ctx, :session_id, session.id)
        )

        emit(:audit_persisted, action, nil, Atom.to_string(outcome))

      {:error, _limited} ->
        emit(:audit_suppressed, action, nil, Atom.to_string(outcome))
    end
  rescue
    exception in [Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
      Logger.error("admin action audit failed: #{action.id} (#{inspect(exception.__struct__)})")

      emit(:audit_failed, action, nil, Atom.to_string(outcome))
  end

  defp valid_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp telemetry_event(:refused), do: :denied
  defp telemetry_event(:conflict), do: :conflicted
  defp telemetry_event(:invalid), do: :invalid
  defp telemetry_event(:failed), do: :failed

  defp emit(event, action, phase, result \\ nil) do
    :telemetry.execute(
      [:simple_fit, :admin_action, event],
      %{count: 1},
      %{action: action.id, phase: phase, result: result}
    )
  end
end
