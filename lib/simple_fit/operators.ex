defmodule SimpleFit.Operators do
  @moduledoc """
  Platform operators (SF-110, ADR 0028): a separately provisioned authority bound
  to one global user, with explicit permissions, WebAuthn security keys and a key
  check bound to the session.

  **Every privileged request goes through one pipeline** (`authorize/4` and the
  writes below), reading the database each time with no cache:

      session (the :authenticated plug) → operator of that user, not suspended or
      revoked → active (keys enrolled) → an active grant of that permission → a
      key check in this session, fresh enough for that permission

  Nothing else confers authority: not an email address, an account, a profile, a
  gym or sponsor role, a client flag or a completed first run. Answers conceal
  operators from everyone else: no operator, a suspended or a revoked one is
  `:not_found`. Refusals of an operator are audited.

  Writes lock the actor's and the target's operator rows (in id order) and the
  session, then authorize again, so a revocation or suspension that commits first
  wins and nothing is decided on a stale answer.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Operators.{Audit, Challenge, Credential, Grant, Operation, Operator, Policy}
  alias SimpleFit.Operators.{StepUp, WebAuthn}
  alias SimpleFit.{RateLimit, Repo}

  defmodule Principal do
    @moduledoc "An operator authorized for one request. An answer, not a pass."
    @enforce_keys [:operator_id, :user_id, :session_id]
    defstruct [:operator_id, :user_id, :session_id]

    @type t :: %__MODULE__{
            operator_id: Ecto.UUID.t(),
            user_id: Ecto.UUID.t(),
            session_id: Ecto.UUID.t()
          }
  end

  @type ctx :: %{optional(:request_id) => String.t() | nil}
  @type refusal :: :not_found | :forbidden | :step_up_required | :enrollment_required
  @type error ::
          refusal()
          | :unauthorized
          | :service_unavailable
          | :security_key_rejected
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | Ecto.Changeset.t()

  @reason ~r/^[a-z][a-z0-9_]{1,59}$/

  ## Current operator

  @doc """
  The viewer's own operator state: status, permissions (while active), keys and
  the key check of this session. `:not_found` for anyone without a usable operator.
  """
  @spec me(User.t(), Session.t()) :: {:ok, map()} | {:error, :not_found}
  def me(%User{} = user, %Session{} = session) do
    case usable_operator(user.id) do
      nil -> {:error, :not_found}
      operator -> {:ok, view(operator, session.id)}
    end
  end

  defp view(operator, session_id) do
    %{
      operator: operator,
      permissions: if(operator.status == :active, do: active_permissions(operator.id), else: []),
      registered_keys: active_credential_count(operator.id),
      required_keys: Policy.required_authenticators(),
      step_up: current_step_up(operator.id, session_id)
    }
  end

  ## Authorization pipeline

  @doc """
  Authorizes `permission` for the viewer now. Reads are allowed only through this;
  writes in this module repeat it under their locks.
  """
  @spec authorize(User.t(), Session.t(), Policy.permission(), ctx()) ::
          {:ok, Principal.t()} | {:error, refusal()}
  def authorize(%User{} = user, %Session{} = session, permission, ctx \\ %{}) do
    case check(usable_operator(user.id), session.id, permission) do
      {:ok, principal} -> {:ok, principal}
      {:error, reason, operator} -> refused(reason, operator, permission, session.id, ctx)
    end
  end

  defp check(nil, _session_id, _permission), do: {:error, :not_found, nil}

  defp check(%Operator{status: :pending_enrollment} = op, _session_id, _permission),
    do: {:error, :enrollment_required, op}

  defp check(%Operator{status: :active} = op, session_id, permission) do
    cond do
      not Policy.permission?(permission) or not granted?(op.id, permission) ->
        {:error, :forbidden, op}

      not step_up_satisfies?(op.id, session_id, Policy.assurance(permission)) ->
        {:error, :step_up_required, op}

      true ->
        {:ok, %Principal{operator_id: op.id, user_id: op.user_id, session_id: session_id}}
    end
  end

  defp check(%Operator{}, _session_id, _permission), do: {:error, :not_found, nil}

  defp refused(reason, operator, permission, session_id, ctx) do
    if operator do
      Audit.record!(
        %{
          action: "operator.access_refused",
          outcome: :refused,
          actor_operator_id: operator.id,
          actor_user_id: operator.user_id,
          permission: permission,
          reason_code: Atom.to_string(reason)
        },
        Map.put(ctx, :session_id, session_id)
      )
    end

    {:error, reason}
  end

  ## Security keys

  @doc """
  Starts registering a security key. A `pending_enrollment` operator may do so with
  their session alone, before the enrolment window closes; an active operator
  needs a fresh key check.
  """
  @spec registration_options(User.t(), Session.t(), ctx()) :: {:ok, map()} | {:error, error()}
  def registration_options(%User{} = user, %Session{} = session, ctx \\ %{}) do
    with :ok <- configured(),
         {:ok, operator} <- enrolling_operator(user.id, session.id, ctx),
         :ok <- limit("operator_challenge", user.id, 20, 3600) do
      {bytes, issued_at} = WebAuthn.new_challenge_bytes()
      challenge = insert_challenge!(operator, session, :registration, bytes, issued_at)
      existing = Repo.all(from(c in Credential, where: c.operator_id == ^operator.id))

      {:ok,
       %{
         challenge_id: challenge.id,
         options: WebAuthn.registration_options(bytes, operator.id, existing)
       }}
    end
  end

  @doc """
  Completes a registration: consumes the challenge (once, even when verification
  fails), verifies the response and stores the public key. Enough keys activate a
  `pending_enrollment` operator in the same transaction.
  """
  @spec register_credential(User.t(), Session.t(), map(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def register_credential(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    types = %{
      challenge_id: Ecto.UUID,
      attestation_object: :string,
      client_data_json: :string,
      label: :string
    }

    with :ok <- concealed(user),
         :ok <- configured(),
         {:ok, attrs} <-
           cast_params(
             params,
             types,
             [:challenge_id, :attestation_object, :client_data_json, :label],
             &validate_length(&1, :label, min: 1, max: 60)
           ),
         {:ok, operator} <- enrolling_operator(user.id, session.id, ctx),
         {:ok, challenge} <-
           consume_challenge(attrs.challenge_id, operator.id, session.id, :registration),
         {:ok, att} <- WebAuthn.decode64(attrs.attestation_object),
         {:ok, cdj} <- WebAuthn.decode64(attrs.client_data_json),
         {:ok, key} <-
           WebAuthn.verify_registration(att, cdj, challenge.challenge, challenge.issued_at),
         :ok <- device_bound(key) do
      store_credential(user, session, operator.id, key, attrs.label, ctx)
    else
      :error -> key_rejected(user.id, session.id, ctx)
      {:error, :security_key_rejected} -> key_rejected(user.id, session.id, ctx)
      other -> other
    end
  end

  # Without attestation a key can't be proven to be hardware. A credential that
  # declares it can be synced to other devices is refused (ADR 0028).
  defp device_bound(%{backup_eligible: true}), do: {:error, :security_key_rejected}

  defp device_bound(_key), do: :ok

  defp store_credential(user, session, operator_id, key, label, ctx) do
    tx(fn ->
      hold_session!(user, session)
      op = lock_operators!([operator_id]) |> Map.fetch!(operator_id)
      enrolling!(op)
      now = DateTime.utc_now()

      credential =
        %Credential{
          operator_id: op.id,
          credential_id: key.credential_id,
          cose_key: key.cose_key,
          sign_count: key.sign_count,
          aaguid: key.aaguid,
          label: label,
          backup_eligible: key.backup_eligible
        }
        |> change()
        |> unique_constraint(:credential_id)
        |> Repo.insert()
        |> case do
          {:ok, credential} -> credential
          {:error, _changeset} -> Repo.rollback({:conflict, %{credential: "already_registered"}})
        end

      audit!(op, "operator.credential_enrolled", ctx, session.id,
        target_type: "credential",
        target_id: credential.id
      )

      op =
        if op.status == :pending_enrollment and
             active_credential_count(op.id) >= Policy.required_authenticators() do
          activated = Repo.update!(change(op, status: :active, activated_at: now))

          audit!(op, "operator.activated", ctx, session.id,
            target_type: "operator",
            target_id: op.id
          )

          activated
        else
          op
        end

      %{credential: credential, operator: op, registered_keys: active_credential_count(op.id)}
    end)
  end

  @doc "The viewer's own security keys (metadata only)."
  @spec list_credentials(User.t(), Session.t()) :: {:ok, [Credential.t()]} | {:error, :not_found}
  def list_credentials(%User{} = user, %Session{} = _session) do
    case usable_operator(user.id) do
      nil ->
        {:error, :not_found}

      op ->
        {:ok,
         Repo.all(from(c in Credential, where: c.operator_id == ^op.id, order_by: c.inserted_at))}
    end
  end

  @doc """
  Revokes one of the viewer's own keys. Needs a fresh key check, and refuses to go
  below the required number: register a replacement first.
  """
  @spec revoke_own_credential(User.t(), Session.t(), Ecto.UUID.t(), ctx()) ::
          {:ok, Credential.t()} | {:error, error()}
  def revoke_own_credential(%User{} = user, %Session{} = session, credential_id, ctx \\ %{}) do
    with {:ok, id} <- uuid(credential_id) do
      tx(fn -> revoke_own!(user, session, id, ctx) end)
      |> refusals("operators.credentials", session.id, ctx)
    end
  end

  defp revoke_own!(user, session, id, ctx) do
    hold_session!(user, session)
    op = own_active_locked!(user.id, session.id, :fresh_key)
    credential = active_credential!(op.id, id)

    if active_credential_count(op.id) <= Policy.required_authenticators() do
      Repo.rollback(
        {:conflict,
         %{credentials: "minimum_required", required: Policy.required_authenticators()}}
      )
    end

    revoked = revoke_credential!(credential, "owner_revoked")

    audit!(op, "operator.credential_revoked", ctx, session.id,
      target_type: "credential",
      target_id: id
    )

    revoked
  end

  ## Step-up

  @doc "Starts a key check for this session."
  @spec step_up_options(User.t(), Session.t(), ctx()) :: {:ok, map()} | {:error, error()}
  def step_up_options(%User{} = user, %Session{} = session, ctx \\ %{}) do
    with :ok <- configured(),
         {:ok, op} <- active_operator(user.id, session.id, ctx),
         :ok <- limit("operator_challenge", user.id, 20, 3600) do
      credentials =
        Repo.all(from(c in Credential, where: c.operator_id == ^op.id and is_nil(c.revoked_at)))

      {bytes, issued_at} = WebAuthn.new_challenge_bytes()
      challenge = insert_challenge!(op, session, :step_up, bytes, issued_at)

      {:ok,
       %{challenge_id: challenge.id, options: WebAuthn.assertion_options(bytes, credentials)}}
    end
  end

  @doc """
  Verifies an assertion and records a key check bound to this session, replacing
  any earlier one. The challenge is consumed even when verification fails.
  """
  @spec verify_step_up(User.t(), Session.t(), map(), ctx()) ::
          {:ok, StepUp.t()} | {:error, error()}
  def verify_step_up(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    types = %{
      challenge_id: Ecto.UUID,
      credential_id: :string,
      authenticator_data: :string,
      client_data_json: :string,
      signature: :string
    }

    with :ok <- concealed(user),
         :ok <- configured(),
         {:ok, attrs} <- cast_params(params, types, Map.keys(types)),
         {:ok, op} <- active_operator(user.id, session.id, ctx),
         :ok <- limit("operator_step_up", user.id, 30, 3600),
         {:ok, challenge} <- consume_challenge(attrs.challenge_id, op.id, session.id, :step_up),
         {:ok, raw_id} <- WebAuthn.decode64(attrs.credential_id),
         {:ok, auth_data} <- WebAuthn.decode64(attrs.authenticator_data),
         {:ok, cdj} <- WebAuthn.decode64(attrs.client_data_json),
         {:ok, signature} <- WebAuthn.decode64(attrs.signature),
         %Credential{} = credential <-
           Repo.one(
             from(c in Credential,
               where:
                 c.operator_id == ^op.id and c.credential_id == ^raw_id and is_nil(c.revoked_at)
             )
           ),
         {:ok, sign_count} <-
           WebAuthn.verify_assertion(
             credential,
             auth_data,
             signature,
             cdj,
             challenge.challenge,
             challenge.issued_at
           ) do
      record_step_up(user, session, op.id, credential.id, sign_count, ctx)
    else
      {:error, reason} when reason in [:service_unavailable, :not_found, :enrollment_required] ->
        {:error, reason}

      {:error, {:rate_limited, _} = limited} ->
        {:error, limited}

      {:error, %Ecto.Changeset{}} = invalid ->
        invalid

      _rejected ->
        key_rejected(user.id, session.id, ctx)
    end
  end

  defp record_step_up(user, session, operator_id, credential_pk, sign_count, ctx) do
    tx(fn ->
      hold_session!(user, session)
      op = lock_operators!([operator_id]) |> Map.fetch!(operator_id)
      if op.status != :active, do: Repo.rollback(:not_found)

      credential =
        Repo.one!(from(c in Credential, where: c.id == ^credential_pk, lock: "FOR UPDATE"))

      if credential.revoked_at || (sign_count != 0 and sign_count <= credential.sign_count) do
        Repo.rollback(:security_key_rejected)
      end

      now = DateTime.utc_now()
      Repo.update!(change(credential, sign_count: sign_count, last_used_at: now))

      revoke_step_ups!(
        from(s in StepUp, where: s.operator_id == ^op.id and s.session_id == ^session.id)
      )

      step_up =
        Repo.insert!(%StepUp{
          operator_id: op.id,
          session_id: session.id,
          credential_id: credential.id,
          verified_at: now,
          expires_at: DateTime.add(now, Policy.step_up_ttl())
        })

      audit!(op, "operator.step_up_verified", ctx, session.id,
        target_type: "credential",
        target_id: credential.id
      )

      step_up
    end)
    |> case do
      {:error, :security_key_rejected} -> key_rejected(user.id, session.id, ctx)
      other -> other
    end
  end

  @doc "Ends this session's key check (leaving the Control Plane)."
  @spec end_step_up(User.t(), Session.t(), ctx()) :: :ok | {:error, :not_found}
  def end_step_up(%User{} = user, %Session{} = session, ctx \\ %{}) do
    case usable_operator(user.id) do
      nil ->
        {:error, :not_found}

      op ->
        revoke_step_ups!(
          from(s in StepUp, where: s.operator_id == ^op.id and s.session_id == ^session.id)
        )

        audit!(op, "operator.step_up_ended", ctx, session.id, [])
        :ok
    end
  end

  ## Operator administration

  @doc "Every operator, with active permissions and key counts (`operators.read`)."
  @spec list_operators(User.t(), Session.t(), ctx()) :: {:ok, [map()]} | {:error, refusal()}
  def list_operators(%User{} = user, %Session{} = session, ctx \\ %{}) do
    with {:ok, _principal} <- authorize(user, session, "operators.read", ctx) do
      ops = Repo.all(from(o in Operator, order_by: [asc: o.inserted_at, asc: o.id]))
      {:ok, Enum.map(ops, &summary/1)}
    end
  end

  @doc "One operator (`operators.read`)."
  @spec get_operator(User.t(), Session.t(), Ecto.UUID.t(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def get_operator(%User{} = user, %Session{} = session, id, ctx \\ %{}) do
    with {:ok, _principal} <- authorize(user, session, "operators.read", ctx),
         {:ok, id} <- uuid(id),
         %Operator{} = op <- Repo.get(Operator, id) do
      {:ok, summary(op)}
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  defp summary(op) do
    %{
      operator: op,
      permissions: if(op.status == :revoked, do: [], else: active_permissions(op.id)),
      registered_keys: active_credential_count(op.id),
      required_keys: Policy.required_authenticators()
    }
  end

  @doc """
  Provisions an operator for an existing account with completed registration
  (`operators.manage`, fresh key check). The new operator holds exactly the listed
  permissions and must register their own keys before anything works. Never for
  the actor's own account.
  """
  @spec provision(User.t(), Session.t(), map(), ctx()) :: {:ok, map()} | {:error, error()}
  def provision(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    types = %{
      user_id: Ecto.UUID,
      permissions: {:array, :string},
      reason_code: :string,
      operation_id: Ecto.UUID
    }

    with :ok <- concealed(user),
         {:ok, attrs} <- cast_params(params, types, Map.keys(types), &validate_permissions/1) do
      write(
        user,
        session,
        nil,
        "operator.provision",
        attrs,
        ctx,
        &provision!(&1, &2, &3, attrs, session, ctx)
      )
    end
  end

  @doc "Grants one permission (`operators.manage`, fresh key check). Never to oneself."
  @spec grant(User.t(), Session.t(), Ecto.UUID.t(), map(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def grant(%User{} = user, %Session{} = session, operator_id, params, ctx \\ %{}) do
    types = %{permission: :string, reason_code: :string, operation_id: Ecto.UUID}

    with :ok <- concealed(user),
         {:ok, target_id} <- uuid(operator_id),
         {:ok, attrs} <-
           cast_params(
             params,
             types,
             Map.keys(types),
             &validate_inclusion(&1, :permission, Policy.permissions())
           ) do
      write(
        user,
        session,
        target_id,
        "operator.grant",
        attrs,
        ctx,
        &grant_one!(&1, &2, &3, attrs, session, ctx)
      )
    end
  end

  @doc "Revokes one permission (`operators.manage`, fresh key check). Never one's own."
  @spec revoke_grant(User.t(), Session.t(), Ecto.UUID.t(), String.t(), map(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def revoke_grant(
        %User{} = user,
        %Session{} = session,
        operator_id,
        permission,
        params,
        ctx \\ %{}
      ) do
    types = %{reason_code: :string, operation_id: Ecto.UUID}

    with :ok <- concealed(user),
         {:ok, target_id} <- uuid(operator_id),
         {:ok, attrs} <- cast_params(params, types, Map.keys(types)) do
      write(
        user,
        session,
        target_id,
        "operator.revoke_grant",
        attrs,
        ctx,
        &revoke_grant!(&1, &2, &3, {permission, attrs}, session, ctx)
      )
    end
  end

  @doc "Suspends an active operator (`operators.manage`, fresh key check). Ends their key checks."
  @spec suspend(User.t(), Session.t(), Ecto.UUID.t(), map(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def suspend(user, session, operator_id, params, ctx \\ %{}),
    do: transition(user, session, operator_id, params, ctx, "operator.suspend", &do_suspend/3)

  @doc """
  Reinstates a suspended operator (`operators.manage`, fresh key check). With fewer
  keys than required they return to `pending_enrollment`.
  """
  @spec reinstate(User.t(), Session.t(), Ecto.UUID.t(), map(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def reinstate(user, session, operator_id, params, ctx \\ %{}),
    do: transition(user, session, operator_id, params, ctx, "operator.reinstate", &do_reinstate/3)

  @doc """
  Revokes an operator for good (`operators.manage`, fresh key check): their grants,
  keys and key checks end in the same transaction.
  """
  @spec revoke(User.t(), Session.t(), Ecto.UUID.t(), map(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def revoke(user, session, operator_id, params, ctx \\ %{}),
    do: transition(user, session, operator_id, params, ctx, "operator.revoke", &do_revoke/3)

  @doc """
  Revokes another operator's lost or compromised key (`operators.manage`, fresh key
  check). With fewer keys than required the operator returns to
  `pending_enrollment` and must register a replacement.
  """
  @spec revoke_operator_credential(
          User.t(),
          Session.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          map(),
          ctx()
        ) ::
          {:ok, map()} | {:error, error()}
  def revoke_operator_credential(user, session, operator_id, credential_id, params, ctx \\ %{}) do
    types = %{reason_code: :string, operation_id: Ecto.UUID}

    with :ok <- concealed(user),
         {:ok, target_id} <- uuid(operator_id),
         {:ok, cred_id} <- uuid(credential_id),
         {:ok, attrs} <- cast_params(params, types, Map.keys(types)) do
      write(
        user,
        session,
        target_id,
        "operator.revoke_credential",
        attrs,
        ctx,
        &revoke_operator_credential!(&1, &2, &3, {cred_id, attrs}, session, ctx)
      )
    end
  end

  defp transition(user, session, operator_id, params, ctx, action, fun) do
    types = %{reason_code: :string, operation_id: Ecto.UUID}

    with :ok <- concealed(user),
         {:ok, target_id} <- uuid(operator_id),
         {:ok, attrs} <- cast_params(params, types, Map.keys(types)) do
      write(user, session, target_id, action, attrs, ctx, fn actor, target, now ->
        not_self!(actor, target)
        updated = fun.(target, actor, now)

        audit!(actor, action <> "d", ctx, session.id,
          target_type: "operator",
          target_id: target.id,
          reason_code: attrs.reason_code,
          operation_id: attrs.operation_id
        )

        summary(updated)
      end)
    end
  end

  defp do_suspend(%Operator{status: :active} = target, _actor, now) do
    revoke_step_ups!(from(s in StepUp, where: s.operator_id == ^target.id))
    Repo.update!(change(target, status: :suspended, suspended_at: now))
  end

  defp do_suspend(_target, _actor, _now), do: Repo.rollback({:conflict, %{status: "not_active"}})

  defp do_reinstate(%Operator{status: :suspended} = target, _actor, now) do
    if active_credential_count(target.id) >= Policy.required_authenticators() do
      Repo.update!(change(target, status: :active, activated_at: target.activated_at || now))
    else
      Repo.update!(
        change(target,
          status: :pending_enrollment,
          enrollment_expires_at: DateTime.add(now, Policy.enrollment_window())
        )
      )
    end
  end

  defp do_reinstate(_target, _actor, _now),
    do: Repo.rollback({:conflict, %{status: "not_suspended"}})

  defp do_revoke(%Operator{status: :revoked}, _actor, _now),
    do: Repo.rollback({:conflict, %{status: "revoked"}})

  defp do_revoke(target, actor, now) do
    revoke_step_ups!(from(s in StepUp, where: s.operator_id == ^target.id))

    Repo.update_all(
      from(c in Credential, where: c.operator_id == ^target.id and is_nil(c.revoked_at)),
      set: [revoked_at: now, revoked_reason: "operator_revoked"]
    )

    Repo.update_all(
      from(g in Grant, where: g.operator_id == ^target.id and is_nil(g.revoked_at)),
      set: [
        revoked_at: now,
        revoked_by_operator_id: actor.id,
        revoke_reason_code: "operator_revoked"
      ]
    )

    Repo.update!(change(target, status: :revoked, revoked_at: now))
  end

  defp provision!(actor, _target, now, attrs, session, ctx) do
    if attrs.user_id == actor.user_id, do: Repo.rollback({:conflict, %{target: "self"}})

    target_user = Repo.get(User, attrs.user_id)

    unless target_user && Accounts.registration_complete?(target_user),
      do: Repo.rollback({:conflict, %{user: "not_eligible"}})

    if usable_or_pending?(attrs.user_id),
      do: Repo.rollback({:conflict, %{operator: "exists"}})

    op =
      %Operator{
        user_id: attrs.user_id,
        status: :pending_enrollment,
        created_by_operator_id: actor.id,
        enrollment_expires_at: DateTime.add(now, Policy.enrollment_window())
      }
      |> change()
      |> unique_constraint(:user_id, name: :platform_operators_one_per_user_index)
      |> Repo.insert()
      |> case do
        {:ok, op} -> op
        {:error, _} -> Repo.rollback({:conflict, %{operator: "exists"}})
      end

    audit!(actor, "operator.provisioned", ctx, session.id,
      target_type: "operator",
      target_id: op.id,
      reason_code: attrs.reason_code,
      operation_id: attrs.operation_id
    )

    Enum.each(attrs.permissions, &grant!(actor, op, &1, attrs, now, ctx, session.id))
    summary(op)
  end

  defp grant_one!(actor, target, now, attrs, session, ctx) do
    not_self!(actor, target)
    if target.status == :revoked, do: Repo.rollback({:conflict, %{operator: "revoked"}})

    if granted?(target.id, attrs.permission),
      do: Repo.rollback({:conflict, %{permission: "already_granted"}})

    grant!(actor, target, attrs.permission, attrs, now, ctx, session.id)
    summary(target)
  end

  defp revoke_grant!(actor, target, now, {permission, attrs}, session, ctx) do
    not_self!(actor, target)

    grant =
      Repo.one(
        from(g in Grant,
          where:
            g.operator_id == ^target.id and g.permission == ^permission and
              is_nil(g.revoked_at),
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

    Repo.update!(
      change(grant,
        revoked_at: now,
        revoked_by_operator_id: actor.id,
        revoke_reason_code: attrs.reason_code
      )
    )

    audit!(actor, "operator.permission_revoked", ctx, session.id,
      target_type: "operator",
      target_id: target.id,
      permission: permission,
      reason_code: attrs.reason_code,
      operation_id: attrs.operation_id
    )

    summary(target)
  end

  defp revoke_operator_credential!(actor, target, now, {cred_id, attrs}, session, ctx) do
    not_self!(actor, target)
    credential = active_credential!(target.id, cred_id)
    revoke_credential!(credential, attrs.reason_code)

    audit!(actor, "operator.credential_revoked", ctx, session.id,
      target_type: "credential",
      target_id: cred_id,
      reason_code: attrs.reason_code,
      operation_id: attrs.operation_id
    )

    target =
      if target.status in [:active, :suspended] and
           active_credential_count(target.id) < Policy.required_authenticators() do
        Repo.update!(
          change(target,
            status: :pending_enrollment,
            enrollment_expires_at: DateTime.add(now, Policy.enrollment_window())
          )
        )
      else
        target
      end

    summary(target)
  end

  ## Audit

  @doc "Audit events, newest first (`audit.read`)."
  @spec list_audit_events(User.t(), Session.t(), map(), ctx()) ::
          {:ok, list()} | {:error, error()}
  def list_audit_events(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    types = %{limit: :integer, before: :utc_datetime_usec}

    with {:ok, _principal} <- authorize(user, session, "audit.read", ctx),
         {:ok, attrs} <-
           cast_params(
             params,
             types,
             [],
             &validate_number(&1, :limit, greater_than: 0, less_than_or_equal_to: 100)
           ) do
      {:ok, Audit.list(Map.get(attrs, :limit, 50), Map.get(attrs, :before))}
    end
  end

  ## The write pipeline

  defp write(user, session, target_id, action, attrs, ctx, fun) do
    permission = "operators.manage"

    tx(fn ->
      hold_session!(user, session)
      actor_id = (usable_operator(user.id) || refuse!(:not_found, nil)).id
      locked = lock_operators!(Enum.uniq(Enum.reject([actor_id, target_id], &is_nil/1)))
      actor = Map.fetch!(locked, actor_id)

      case check(actor, session.id, permission) do
        {:ok, _principal} -> :ok
        {:error, reason, op} -> refuse!(reason, op)
      end

      target = if target_id, do: Map.get(locked, target_id) || Repo.rollback(:not_found)
      repeated!(attrs.operation_id, actor.id, action)
      result = fun.(actor, target, DateTime.utc_now())
      record_operation!(attrs.operation_id, actor.id, action, result.operator.id)
      result
    end)
    |> case do
      {:error, {:duplicate, operator_id}} -> {:ok, summary(Repo.get!(Operator, operator_id))}
      other -> refusals(other, permission, session.id, ctx)
    end
  end

  defp refusals({:error, {:refused, reason, op}}, permission, session_id, ctx),
    do: refused(reason, op, permission, session_id, ctx)

  defp refusals(result, _permission, _session_id, _ctx), do: result

  # A repeated operation id answers with the current state and changes nothing; the same
  # id used for something else is a conflict. Two concurrent repeats meet on the primary key.
  defp repeated!(operation_id, actor_id, action) do
    case Repo.get(Operation, operation_id) do
      nil ->
        :ok

      %Operation{actor_operator_id: ^actor_id, action: ^action} = op ->
        Repo.rollback({:duplicate, op.target_id})

      _other ->
        Repo.rollback({:conflict, %{operation_id: "reused"}})
    end
  end

  defp record_operation!(operation_id, actor_id, action, target_id) do
    %Operation{
      id: operation_id,
      actor_operator_id: actor_id,
      action: action,
      target_id: target_id
    }
    |> change()
    |> unique_constraint(:id, name: :operator_operations_pkey)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> Repo.rollback({:conflict, %{operation_id: "concurrent"}})
    end
  end

  defp refuse!(reason, op), do: Repo.rollback({:refused, reason, op})

  defp grant!(actor, target, permission, attrs, now, ctx, session_id) do
    %Grant{
      operator_id: target.id,
      permission: permission,
      granted_by_operator_id: actor.id,
      reason_code: attrs.reason_code,
      operation_id: attrs.operation_id,
      granted_at: now
    }
    |> change()
    |> unique_constraint([:operator_id, :permission],
      name: :operator_permission_grants_one_active_index
    )
    |> Repo.insert()
    |> case do
      {:ok, _grant} -> :ok
      {:error, _} -> Repo.rollback({:conflict, %{permission: "already_granted"}})
    end

    audit!(actor, "operator.permission_granted", ctx, session_id,
      target_type: "operator",
      target_id: target.id,
      permission: permission,
      reason_code: attrs.reason_code,
      operation_id: attrs.operation_id
    )
  end

  defp not_self!(actor, target) do
    if actor.id == target.id, do: Repo.rollback({:conflict, %{target: "self"}})
  end

  ## Shared helpers

  # Before anything else reads the request: an account without a usable operator learns
  # nothing, not even that a body was malformed.
  defp concealed(%User{id: id}), do: if(usable_operator(id), do: :ok, else: {:error, :not_found})

  # An operator whose account can use operator endpoints at all: not suspended, not revoked.
  defp usable_operator(user_id) do
    Repo.one(
      from(o in Operator,
        where: o.user_id == ^user_id and o.status in [:pending_enrollment, :active]
      ),
      log: false
    )
  end

  defp usable_or_pending?(user_id),
    do: Repo.exists?(from(o in Operator, where: o.user_id == ^user_id and o.status != :revoked))

  defp enrolling_operator(user_id, session_id, ctx) do
    case usable_operator(user_id) do
      nil -> {:error, :not_found}
      %Operator{status: :pending_enrollment} = op -> enrolling_window(op)
      %Operator{status: :active} = op -> fresh_or_refuse(op, session_id, ctx)
    end
  end

  defp enrolling_window(op) do
    if DateTime.compare(op.enrollment_expires_at, DateTime.utc_now()) == :gt,
      do: {:ok, op},
      else: {:error, {:conflict, %{enrollment: "expired"}}}
  end

  defp fresh_or_refuse(op, session_id, ctx) do
    if step_up_satisfies?(op.id, session_id, :fresh_key),
      do: {:ok, op},
      else: refused(:step_up_required, op, "operators.credentials", session_id, ctx)
  end

  defp enrolling!(%Operator{status: :pending_enrollment} = op) do
    case enrolling_window(op) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp enrolling!(%Operator{status: :active}), do: :ok
  defp enrolling!(_op), do: Repo.rollback(:not_found)

  defp active_operator(user_id, _session_id, _ctx) do
    case usable_operator(user_id) do
      nil -> {:error, :not_found}
      %Operator{status: :pending_enrollment} -> {:error, :enrollment_required}
      op -> {:ok, op}
    end
  end

  defp own_active_locked!(user_id, session_id, assurance) do
    op = usable_operator(user_id) || Repo.rollback(:not_found)
    op = lock_operators!([op.id]) |> Map.fetch!(op.id)
    if op.status != :active, do: Repo.rollback(:not_found)

    unless step_up_satisfies?(op.id, session_id, assurance) do
      Repo.rollback({:refused, :step_up_required, op})
    end

    op
  end

  defp lock_operators!(ids) do
    from(o in Operator, where: o.id in ^ids, order_by: o.id, lock: "FOR UPDATE")
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp hold_session!(user, session) do
    case Accounts.hold_active_session(user, session) do
      :ok -> :ok
      _revoked -> Repo.rollback(:session_revoked)
    end
  end

  defp granted?(operator_id, permission) do
    Repo.exists?(
      from(g in Grant,
        where:
          g.operator_id == ^operator_id and g.permission == ^permission and is_nil(g.revoked_at)
      )
    )
  end

  defp active_permissions(operator_id) do
    Repo.all(
      from(g in Grant,
        where: g.operator_id == ^operator_id and is_nil(g.revoked_at),
        order_by: g.permission,
        select: g.permission
      )
    )
  end

  defp active_credential_count(operator_id) do
    Repo.aggregate(
      from(c in Credential, where: c.operator_id == ^operator_id and is_nil(c.revoked_at)),
      :count
    )
  end

  defp active_credential!(operator_id, id) do
    Repo.one(
      from(c in Credential,
        where: c.id == ^id and c.operator_id == ^operator_id and is_nil(c.revoked_at),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp revoke_credential!(credential, reason) do
    now = DateTime.utc_now()
    revoke_step_ups!(from(s in StepUp, where: s.credential_id == ^credential.id))
    Repo.update!(change(credential, revoked_at: now, revoked_reason: reason))
  end

  defp revoke_step_ups!(query) do
    Repo.update_all(from(s in query, where: is_nil(s.revoked_at)),
      set: [revoked_at: DateTime.utc_now()]
    )
  end

  defp current_step_up(operator_id, session_id) do
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

  defp step_up_satisfies?(operator_id, session_id, assurance) do
    case current_step_up(operator_id, session_id) do
      nil ->
        false

      step_up ->
        assurance == :key or
          DateTime.diff(DateTime.utc_now(), step_up.verified_at) <= Policy.fresh_window()
    end
  end

  @doc "Seconds a key check of this session still counts as fresh, or 0."
  @spec fresh_remaining(StepUp.t() | nil) :: non_neg_integer()
  def fresh_remaining(nil), do: 0

  def fresh_remaining(%StepUp{} = step_up) do
    max(Policy.fresh_window() - DateTime.diff(DateTime.utc_now(), step_up.verified_at), 0)
  end

  defp insert_challenge!(operator, session, purpose, bytes, issued_at) do
    Repo.insert!(%Challenge{
      operator_id: operator.id,
      session_id: session.id,
      purpose: purpose,
      challenge: bytes,
      issued_at: issued_at,
      expires_at: DateTime.add(DateTime.utc_now(), Policy.challenge_ttl())
    })
  end

  # Atomic and committed on its own: a challenge is spent even if verification fails.
  defp consume_challenge(id, operator_id, session_id, purpose) do
    now = DateTime.utc_now()

    query =
      from(c in Challenge,
        where:
          c.id == ^id and c.operator_id == ^operator_id and c.session_id == ^session_id and
            c.purpose == ^purpose and is_nil(c.consumed_at) and c.expires_at > ^now,
        select: c
      )

    case Repo.update_all(query, set: [consumed_at: now]) do
      {1, [challenge]} -> {:ok, challenge}
      _ -> {:error, :security_key_rejected}
    end
  end

  defp key_rejected(user_id, session_id, ctx) do
    case Repo.one(from(o in Operator, where: o.user_id == ^user_id and o.status != :revoked)) do
      nil -> :ok
      op -> audit_refused!(op, "operator.security_key_rejected", ctx, session_id)
    end

    {:error, :security_key_rejected}
  end

  defp audit!(op, action, ctx, session_id, fields) do
    Audit.record!(
      Map.merge(
        %{action: action, outcome: :allowed, actor_operator_id: op.id, actor_user_id: op.user_id},
        Map.new(fields)
      ),
      Map.merge(ctx, %{session_id: session_id, operation_id: Keyword.get(fields, :operation_id)})
    )
  end

  defp audit_refused!(op, action, ctx, session_id) do
    Audit.record!(
      %{action: action, outcome: :refused, actor_operator_id: op.id, actor_user_id: op.user_id},
      Map.put(ctx, :session_id, session_id)
    )
  end

  defp configured do
    if WebAuthn.configured?(), do: :ok, else: {:error, :service_unavailable}
  end

  defp limit(bucket, user_id, count, period) do
    RateLimit.hit([{bucket, :crypto.hash(:sha256, user_id), count, period}])
  end

  defp tx(fun), do: Repo.transaction(fun)

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp cast_params(params, types, required, extra \\ & &1) do
    {%{}, types}
    |> cast(params, Map.keys(types))
    |> validate_required(required)
    |> then(fn cs ->
      if Map.has_key?(types, :reason_code),
        do: validate_format(cs, :reason_code, @reason),
        else: cs
    end)
    |> extra.()
    |> apply_action(:validate)
  end

  defp validate_permissions(changeset) do
    validate_change(changeset, :permissions, fn :permissions, permissions ->
      cond do
        permissions == [] ->
          [permissions: {"must not be empty", validation: :length}]

        permissions != Enum.uniq(permissions) ->
          [permissions: {"has duplicates", validation: :unique}]

        Enum.all?(permissions, &Policy.permission?/1) ->
          []

        true ->
          [permissions: {"is invalid", validation: :inclusion}]
      end
    end)
  end
end
