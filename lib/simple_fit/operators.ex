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
  import SimpleFit.Operators.Authority

  alias SimpleFit.Operators.{Actions, Audit, AuditEvent, Challenge, Credential, Cursor, Grant}
  alias SimpleFit.Operators.{Operation, Operator, Overview, Policy, Principal, Redaction}
  alias SimpleFit.Operators.{StepUp, WebAuthn}
  alias SimpleFit.{RateLimit, Repo}
  alias SimpleFit.Sponsors.Review

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
  Whether the user is an **active** operator (enrolled, not suspended or revoked), for
  presentation only (SF-120: the Control Plane first run is offered to active operators).
  It authorizes nothing: every operator call checks permission and key on its own.
  """
  @spec active_operator?(User.t()) :: boolean()
  def active_operator?(%User{id: user_id}) when is_binary(user_id) do
    match?(%{status: :active}, usable_operator(user_id))
  end

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

  @doc "One operator (`operators.read`). Each view is audited (`operator.viewed`)."
  @spec get_operator(User.t(), Session.t(), Ecto.UUID.t(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def get_operator(%User{} = user, %Session{} = session, id, ctx \\ %{}) do
    project("operators.detail", user, session, ctx, fn _principal ->
      with {:ok, id} <- uuid(id),
           %Operator{} = op <- Repo.get(Operator, id) do
        {:ok, summary(op), {"operator", op.id}}
      else
        _ -> {:error, :not_found}
      end
    end)
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

  ## Admin actions (SF-111): declared, previewed, confirmed, revision-checked

  @doc """
  Previews a declared admin action (`SimpleFit.Operators.OperatorActions`) on
  `target_id`: current and proposed state, impact, what it needs, and a one-time
  confirmation when the action requires one. Changes nothing else.
  """
  @spec preview(String.t(), User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def preview(action_id, %User{} = user, %Session{} = session, target_id, params, ctx \\ %{}),
    do: Actions.preview(action_id, user, session, target_id, params, ctx)

  @doc """
  Executes a declared admin action on `target_id`: authorization under locks, the
  expected revision, the confirmation, the change and its audit in one transaction.
  """
  @spec execute(String.t(), User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def execute(action_id, %User{} = user, %Session{} = session, target_id, params, ctx \\ %{}),
    do: Actions.execute(action_id, user, session, target_id, params, ctx)

  @doc "Grants one permission (`operator.permission.grant`). Never to oneself."
  @spec grant(User.t(), Session.t(), Ecto.UUID.t(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def grant(user, session, operator_id, params, ctx \\ %{}),
    do: execute("operator.permission.grant", user, session, operator_id, params, ctx)

  @doc "Revokes one permission (`operator.permission.revoke`). Never one's own."
  @spec revoke_grant(User.t(), Session.t(), Ecto.UUID.t(), String.t(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def revoke_grant(user, session, operator_id, permission, params, ctx \\ %{}),
    do:
      execute(
        "operator.permission.revoke",
        user,
        session,
        operator_id,
        Map.put(params, "permission", permission),
        ctx
      )

  @doc "Suspends an active operator (`operator.suspend`). Ends their key checks."
  @spec suspend(User.t(), Session.t(), Ecto.UUID.t(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def suspend(user, session, operator_id, params, ctx \\ %{}),
    do: execute("operator.suspend", user, session, operator_id, params, ctx)

  @doc """
  Reinstates a suspended operator (`operator.reinstate`). With fewer keys than
  required they return to `pending_enrollment`.
  """
  @spec reinstate(User.t(), Session.t(), Ecto.UUID.t(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def reinstate(user, session, operator_id, params, ctx \\ %{}),
    do: execute("operator.reinstate", user, session, operator_id, params, ctx)

  @doc """
  Revokes an operator for good (`operator.revoke`): their grants, keys and key
  checks end in the same transaction.
  """
  @spec revoke(User.t(), Session.t(), Ecto.UUID.t(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def revoke(user, session, operator_id, params, ctx \\ %{}),
    do: execute("operator.revoke", user, session, operator_id, params, ctx)

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

  ## Privileged reads (SF-111)

  # Each read projection: the permission it needs and the audit action recorded for
  # each read (nil: not audited). Responses are built from allowlisted DTOs
  # (`SimpleFitWeb.OperatorJSON`, `SimpleFit.Operators.Redaction`).
  @projections %{
    "operators.detail" => %{permission: "operators.read", audit: "operator.viewed"},
    "audit.events" => %{permission: "audit.read", audit: "audit.events_read"},
    "audit.event" => %{permission: "audit.read", audit: "audit.event_viewed"},
    "sponsor_applications.detail" => %{
      permission: "sponsors.applications.read",
      audit: "sponsor_application.viewed"
    },
    "sponsor_applications.queue" => %{
      permission: "sponsors.applications.read",
      audit: "sponsor_applications.queue_read"
    },
    "sponsor_applications.file" => %{
      permission: "sponsors.applications.read_files",
      audit: "sponsor_application.file_downloaded"
    },
    "users.search" => %{permission: "users.read", audit: "user.searched"},
    "users.detail" => %{permission: "users.read", audit: "user.viewed"},
    "users.email" => %{permission: "users.reveal_email", audit: "user.email_revealed"},
    "gyms.list" => %{permission: "gyms.read", audit: "gyms.listed"},
    "gyms.detail" => %{permission: "gyms.read", audit: "gym.viewed"},
    "coaches.search" => %{permission: "coaches.read", audit: "coach.searched"},
    "coaches.detail" => %{permission: "coaches.read", audit: "coach.viewed"},
    "fighters.search" => %{permission: "fighters.read", audit: "fighter.searched"},
    "fighters.detail" => %{permission: "fighters.read", audit: "fighter.viewed"}
  }

  defp project(id, user, session, ctx, fun) do
    %{permission: permission, audit: audit_action} = Map.fetch!(@projections, id)

    with {:ok, principal} <- authorize(user, session, permission, ctx),
         {:ok, result, {target_type, target_id}, extra} <- with_extra(fun.(principal)) do
      Audit.record!(
        Map.merge(extra, %{
          action: audit_action,
          command: id,
          outcome: :allowed,
          actor_operator_id: principal.operator_id,
          actor_user_id: principal.user_id,
          permission: permission,
          target_type: target_type,
          target_id: target_id
        }),
        Map.put(ctx, :session_id, session.id)
      )

      {:ok, result}
    end
  end

  @doc """
  One page of audit events, newest first (`audit.read`). Filters: `actor_operator_id`,
  `action`, `command`, `target_type`, `target_id`, `outcome`, `occurred_after`,
  `occurred_before`; `limit` 1..100 (default 50); `cursor` from the previous page,
  valid only for the same filters and reader. `before` (SF-110) still pages by time
  and can't be combined with `cursor`. Each query is audited (`audit.events_read`).
  """
  @spec list_audit_events(User.t(), Session.t(), map(), ctx()) ::
          {:ok, %{events: list(), next_cursor: String.t() | nil}} | {:error, error()}
  def list_audit_events(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    project("audit.events", user, session, ctx, fn principal ->
      with {:ok, attrs} <- audit_query(params),
           {:ok, position} <- audit_position(attrs, principal.operator_id) do
        filters = audit_filters(attrs)
        {events, next} = Audit.page(filters, Map.get(attrs, :limit, 50), position)

        {:ok,
         %{
           events: events,
           next_cursor: next && Cursor.encode(next, filters, principal.operator_id)
         }, {"audit_log", nil}}
      end
    end)
  end

  @doc """
  A submitted sponsor application for review (`sponsors.applications.read`, SF-114):
  status, the latest submission, the open change request and the submitted
  documents' metadata. Drafts are not found. Each view is audited.
  """
  @spec get_sponsor_application(User.t(), Session.t(), term(), ctx()) ::
          {:ok, map()} | {:error, error()}
  def get_sponsor_application(%User{} = user, %Session{} = session, id, ctx \\ %{}) do
    project("sponsor_applications.detail", user, session, ctx, fn _principal ->
      with {:ok, id} <- uuid(id),
           %{} = application <- Review.fetch(id) do
        {:ok, Review.view(application), {"sponsor_application", application.id}}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc """
  One page of the sponsor application review queue (`sponsors.applications.read`,
  SF-116), oldest submission first. Filters: `status` (any status but `draft`),
  `submitted_after`, `submitted_before`; `limit` 1..100 (default 50); `cursor` from
  the previous page, valid only for the same filters and reader. Drafts never
  appear. Each query is audited (`sponsor_applications.queue_read`).
  """
  @spec list_sponsor_applications(User.t(), Session.t(), map(), ctx()) ::
          {:ok, %{applications: list(), next_cursor: String.t() | nil}} | {:error, error()}
  def list_sponsor_applications(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    project("sponsor_applications.queue", user, session, ctx, fn principal ->
      with {:ok, attrs} <- queue_query(params),
           filters = queue_filters(attrs),
           {:ok, position} <- queue_position(attrs, filters, principal.operator_id) do
        {rows, next} = Review.queue(filters, Map.get(attrs, :limit, 50), position)

        {:ok,
         %{
           applications: rows,
           next_cursor: next && Cursor.encode(next, filters, principal.operator_id)
         }, {"sponsor_application_queue", nil}}
      end
    end)
  end

  @doc """
  A short-lived (5 minutes), attachment-only presigned download of one submitted
  document of a submitted application (`sponsors.applications.read_files` with a
  fresh key check, SF-116). Never a draft's or an unsubmitted file, never the
  operator's own application. Audited (`sponsor_application.file_downloaded`, the
  document as target) before the URL is returned; the URL itself is never stored or
  logged.
  """
  @spec download_sponsor_application_document(User.t(), Session.t(), term(), term(), ctx()) ::
          {:ok, SimpleFit.Storage.Presigned.t()} | {:error, error() | term()}
  def download_sponsor_application_document(
        %User{} = user,
        %Session{} = session,
        application_id,
        evidence_id,
        ctx \\ %{}
      ) do
    project("sponsor_applications.file", user, session, ctx, fn principal ->
      with {:ok, id} <- uuid(application_id),
           %{} = application <- Review.fetch(id),
           false <- application.applicant_user_id == principal.user_id,
           %{} = document <- Review.submitted_document(application, evidence_id),
           {:ok, download} <-
             SimpleFit.Storage.presign_download(document.object_key,
               expires_in: 300,
               attachment: true
             ) do
        {:ok, download, {"sponsor_application_evidence", document.id}}
      else
        true -> {:error, {:conflict, %{target: "self"}}}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc "One audit event (`audit.read`). Each view is audited (`audit.event_viewed`)."
  @spec get_audit_event(User.t(), Session.t(), term(), ctx()) ::
          {:ok, AuditEvent.t()} | {:error, error()}
  def get_audit_event(%User{} = user, %Session{} = session, id, ctx \\ %{}) do
    project("audit.event", user, session, ctx, fn _principal ->
      with {:ok, id} <- uuid(id),
           %AuditEvent{} = event <- Audit.get(id) do
        {:ok, event, {"audit_event", event.id}}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  @audit_filters [
    :actor_operator_id,
    :action,
    :command,
    :target_type,
    :target_id,
    :outcome,
    :occurred_after,
    :occurred_before
  ]

  defp audit_query(params) do
    types = %{
      limit: :integer,
      cursor: :string,
      before: :utc_datetime_usec,
      actor_operator_id: Ecto.UUID,
      action: :string,
      command: :string,
      target_type: :string,
      target_id: Ecto.UUID,
      outcome: :string,
      occurred_after: :utc_datetime_usec,
      occurred_before: :utc_datetime_usec
    }

    {%{}, types}
    |> cast(params, Map.keys(types))
    |> validate_number(:limit, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_format(:action, ~r/^[a-z][a-z0-9_.]{1,79}$/)
    |> validate_format(:command, ~r/^[a-z][a-z0-9_.]{1,79}$/)
    |> validate_format(:target_type, ~r/^[a-z][a-z0-9_]{1,39}$/)
    |> validate_inclusion(:outcome, ~w(allowed refused conflict invalid failed))
    |> validate_length(:cursor, max: 1024)
    |> validate_exclusive(:cursor, :before)
    |> validate_range()
    |> apply_action(:validate)
  end

  defp queue_query(params) do
    types = %{
      limit: :integer,
      cursor: :string,
      status: :string,
      submitted_after: :utc_datetime_usec,
      submitted_before: :utc_datetime_usec
    }

    {%{}, types}
    |> cast(params, Map.keys(types))
    |> validate_number(:limit, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_inclusion(:status, Enum.map(Review.queue_statuses(), &Atom.to_string/1))
    |> validate_length(:cursor, max: 1024)
    |> apply_action(:validate)
  end

  # The scope a queue cursor is bound to: the filters and which list it pages.
  defp queue_filters(attrs) do
    attrs
    |> Map.take([:status, :submitted_after, :submitted_before])
    |> Map.update(:status, nil, &String.to_existing_atom/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.put(:queue, "sponsor_applications")
  end

  defp queue_position(%{cursor: cursor}, filters, operator_id) do
    case Cursor.decode(cursor, filters, operator_id) do
      {:ok, position} ->
        {:ok, position}

      :error ->
        {:error,
         {%{}, %{cursor: :string}}
         |> change()
         |> add_error(:cursor, "is invalid", validation: :format)}
    end
  end

  defp queue_position(_attrs, _filters, _operator_id), do: {:ok, nil}

  defp validate_exclusive(changeset, one, other) do
    if get_change(changeset, one) && get_change(changeset, other),
      do: add_error(changeset, other, "can't be combined with #{one}", validation: :exclusive),
      else: changeset
  end

  defp validate_range(changeset) do
    with %DateTime{} = from <- get_change(changeset, :occurred_after),
         %DateTime{} = to <- get_change(changeset, :occurred_before),
         :lt <- DateTime.compare(from, to) do
      changeset
    else
      nil ->
        changeset

      _ ->
        add_error(changeset, :occurred_before, "must be after occurred_after", validation: :range)
    end
  end

  defp audit_filters(attrs) do
    attrs
    |> Map.take(@audit_filters)
    |> Map.update(:outcome, nil, &String.to_existing_atom/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp audit_position(%{cursor: cursor} = attrs, operator_id) do
    case Cursor.decode(cursor, audit_filters(attrs), operator_id) do
      {:ok, position} ->
        {:ok, position}

      :error ->
        {:error,
         {%{}, %{cursor: :string}}
         |> change()
         |> add_error(:cursor, "is invalid", validation: :format)}
    end
  end

  # SF-110's `before`: everything strictly older than that time.
  defp audit_position(%{before: %DateTime{} = before}, _operator_id),
    do: {:ok, {before, "00000000-0000-0000-0000-000000000000"}}

  defp audit_position(_attrs, _operator_id), do: {:ok, nil}

  # A read may add audit fields (its reason code); most don't.
  defp with_extra({:ok, result, target}), do: {:ok, result, target, %{}}
  defp with_extra({:ok, _result, _target, %{}} = answer), do: answer
  defp with_extra(other), do: other

  ## User administration (SF-122)

  @user_read_reasons ~w(support_request account_security abuse_report legal_request)
  @user_search_limit 60

  @doc "Reason codes a user read is recorded with (proposed operational defaults)."
  @spec user_read_reasons() :: [String.t()]
  def user_read_reasons, do: @user_read_reasons

  @doc """
  Finds one account by exact user id or exact email address (`users.read`, key check).
  Never a partial match or a list: at most one result, with masked addresses. Needs a
  `reason_code`; every search is recorded with it (`user.searched`), found or not, and
  limited to #{@user_search_limit} per operator and hour.
  """
  @spec search_users(User.t(), Session.t(), map(), ctx()) ::
          {:ok, %{users: [map()]}} | {:error, error() | term()}
  def search_users(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    with {:ok, attrs} <- user_query(params, [:query, :reason_code], %{query: :string}) do
      project("users.search", user, session, ctx, &search_projection(&1, attrs))
    end
  end

  @doc """
  One account (`users.read`, key check): masked addresses, sign-in methods,
  registration, account state, active sessions (start and end), last sign-in and
  context counts. Needs a `reason_code`; recorded (`user.viewed`).
  """
  @spec get_user(User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, error() | term()}
  def get_user(%User{} = user, %Session{} = session, user_id, params, ctx \\ %{}) do
    with {:ok, attrs} <- user_query(params, [:reason_code], %{}),
         {:ok, id} <- user_id(user_id) do
      project("users.detail", user, session, ctx, fn _principal ->
        detail_projection(id, attrs)
      end)
    end
  end

  @doc """
  An account's full email addresses (`users.reveal_email`, fresh key check). Needs a
  `reason_code`; recorded (`user.email_revealed`) before the addresses are returned.
  """
  @spec reveal_user_email(User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, %{email_addresses: [String.t()]}} | {:error, error() | term()}
  def reveal_user_email(%User{} = user, %Session{} = session, user_id, params, ctx \\ %{}) do
    with {:ok, attrs} <- user_query(params, [:reason_code], %{}),
         {:ok, id} <- user_id(user_id) do
      project("users.email", user, session, ctx, fn _principal -> email_projection(id, attrs) end)
    end
  end

  defp search_projection(principal, attrs) do
    with :ok <- user_search_limit(principal) do
      found = Accounts.find_for_admin(attrs.query)
      users = if found, do: [user_summary(found)], else: []
      {:ok, %{users: users}, {"user", found}, %{reason_code: attrs.reason_code}}
    end
  end

  defp detail_projection(id, attrs) do
    case user_detail(id) do
      nil -> {:error, :not_found}
      detail -> {:ok, detail, {"user", id}, %{reason_code: attrs.reason_code}}
    end
  end

  defp email_projection(id, attrs) do
    case Accounts.admin_view(id) do
      nil ->
        {:error, :not_found}

      view ->
        {:ok, %{email_addresses: view.email_addresses}, {"user", id},
         %{reason_code: attrs.reason_code}}
    end
  end

  defp user_query(params, required, types) do
    types = Map.put(types, :reason_code, :string)

    {%{}, types}
    |> cast(params, Map.keys(types))
    |> validate_required(required)
    |> validate_inclusion(:reason_code, @user_read_reasons)
    |> then(
      &if(Map.has_key?(types, :query),
        do: validate_length(&1, :query, min: 1, max: 320),
        else: &1
      )
    )
    |> apply_action(:validate)
  end

  defp user_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp user_search_limit(principal) do
    RateLimit.hit([
      {"operator_user_search", :crypto.hash(:sha256, principal.user_id), @user_search_limit, 3600}
    ])
  end

  defp user_summary(id) do
    detail = user_detail(id)
    Map.take(detail, [:id, :name, :joined_at, :status, :masked_emails, :contexts])
  end

  defp user_detail(id) do
    case Accounts.admin_view(id) do
      nil ->
        nil

      view ->
        view
        |> Map.drop([:email_addresses, :suspension])
        |> Map.merge(%{
          masked_emails: Enum.map(view.email_addresses, &Redaction.mask_email/1),
          suspension:
            view.suspension &&
              %{since: view.suspension.started_at, reason_code: view.suspension.reason_code},
          contexts: contexts(id)
        })
    end
  end

  defp contexts(id) do
    gyms = SimpleFit.Gyms.relationship_counts(id)

    %{
      fighter_profile: SimpleFit.Fighters.profile_status(id),
      coach_profile: SimpleFit.Coaches.profile_status(id),
      gym_staff: gyms.staff,
      gym_member: gyms.member,
      sponsor_memberships: SimpleFit.Sponsors.active_membership_count(id),
      platform_operator: usable_operator(id) != nil
    }
  end

  ## Gym, coach and fighter oversight (SF-123)

  @profile_search_limit 60

  @doc """
  One page of gyms, newest first (`gyms.read`, key check): name, type, lifecycle,
  verification status, primary country and city, active staff count, creation time.
  Filters: `query` (a case-insensitive name prefix, 1..80), `lifecycle`,
  `verification`, `country` (ISO alpha-2); `limit` 1..50 (default 25); `cursor` from
  the previous page, valid only for the same filters and reader. No member data.
  Each query is audited (`gyms.listed`).
  """
  @spec list_gyms(User.t(), Session.t(), map(), ctx()) ::
          {:ok, %{gyms: [map()], next_cursor: String.t() | nil}} | {:error, error() | term()}
  def list_gyms(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    project("gyms.list", user, session, ctx, fn principal ->
      with {:ok, attrs} <- gym_query(params),
           filters = gym_filters(attrs),
           {:ok, position} <- gym_position(attrs, filters, principal.operator_id) do
        {gyms, next} =
          SimpleFit.Gyms.oversight_page(
            Map.delete(filters, :list),
            Map.get(attrs, :limit, 25),
            position
          )

        {:ok,
         %{gyms: gyms, next_cursor: next && Cursor.encode(next, filters, principal.operator_id)},
         {"gym_list", nil}}
      end
    end)
  end

  @doc """
  One gym (`gyms.read`, key check), read in one snapshot: its state, the owner (user
  id and short name), active staff counts by role, pending staff invitations, member
  counts (never who), and the verification application's status, revision and dates
  (never its business details or documents). Needs a `reason_code`; recorded
  (`gym.viewed`).
  """
  @spec get_gym(User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, error() | term()}
  def get_gym(%User{} = user, %Session{} = session, gym_id, params, ctx \\ %{}) do
    with {:ok, attrs} <- user_query(params, [:reason_code], %{}),
         {:ok, id} <- user_id(gym_id) do
      project("gyms.detail", user, session, ctx, fn _principal -> read_gym(id, attrs) end)
    end
  end

  @doc """
  Finds one coach by the exact email address or user id of their account
  (`coaches.read`, key check). At most one result; never a partial match or a list.
  Needs a `reason_code`; every search is recorded (`coach.searched`), found or not,
  and shares a limit of #{@profile_search_limit} profile searches per operator and hour.
  """
  @spec search_coaches(User.t(), Session.t(), map(), ctx()) ::
          {:ok, %{coaches: [map()]}} | {:error, error() | term()}
  def search_coaches(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    with {:ok, attrs} <- user_query(params, [:query, :reason_code], %{query: :string}) do
      project("coaches.search", user, session, ctx, fn principal ->
        profile_search(principal, attrs, :coach)
      end)
    end
  end

  @doc """
  One coach (`coaches.read`, key check): the profile's professional fields, onboarding
  and account status, relationship counts (active, ended, pending invitations) and the
  gyms they coach at (ids only). Never the bio, training, notes, messages or who their
  fighters are. Needs a `reason_code`; recorded (`coach.viewed`).
  """
  @spec get_coach(User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, error() | term()}
  def get_coach(%User{} = user, %Session{} = session, coach_id, params, ctx \\ %{}) do
    profile_detail(user, session, coach_id, params, ctx, :coach)
  end

  @doc """
  Finds one fighter by exact `@username`, or by the exact email address or user id of
  their account (`fighters.read`, key check). At most one result. Needs a
  `reason_code`; every search is recorded (`fighter.searched`), found or not, and
  shares the profile search limit.
  """
  @spec search_fighters(User.t(), Session.t(), map(), ctx()) ::
          {:ok, %{fighters: [map()]}} | {:error, error() | term()}
  def search_fighters(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    with {:ok, attrs} <- user_query(params, [:query, :reason_code], %{query: :string}) do
      project("fighters.search", user, session, ctx, fn principal ->
        profile_search(principal, attrs, :fighter)
      end)
    end
  end

  @doc """
  One fighter (`fighters.read`, key check): the fields a fighter shares with an
  accepted coach (no bout count), onboarding and account status, relationship counts
  and active gym membership count. Never weight, height, goals, fights, age, health,
  training, notes or messages. Needs a `reason_code`; recorded (`fighter.viewed`).
  """
  @spec get_fighter(User.t(), Session.t(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, error() | term()}
  def get_fighter(%User{} = user, %Session{} = session, fighter_id, params, ctx \\ %{}) do
    profile_detail(user, session, fighter_id, params, ctx, :fighter)
  end

  defp gym_query(params) do
    types = %{
      query: :string,
      lifecycle: :string,
      verification: :string,
      country: :string,
      limit: :integer,
      cursor: :string
    }

    {%{}, types}
    |> cast(params, Map.keys(types), empty_values: [])
    |> validate_length(:query, min: 1, max: 80)
    |> validate_inclusion(:lifecycle, ~w(draft completed))
    |> validate_inclusion(
      :verification,
      Enum.map(SimpleFit.Gyms.oversight_verification_statuses(), &Atom.to_string/1)
    )
    |> validate_format(:country, ~r/^[A-Z]{2}$/)
    |> validate_number(:limit, greater_than: 0, less_than_or_equal_to: 50)
    |> validate_length(:cursor, max: 1024)
    |> apply_action(:validate)
  end

  # The scope a gym list cursor is bound to: the filters and which list it pages.
  defp gym_filters(attrs) do
    %{
      name_prefix: attrs[:query],
      lifecycle: attrs[:lifecycle] && String.to_existing_atom(attrs.lifecycle),
      verification: attrs[:verification] && String.to_existing_atom(attrs.verification),
      country: attrs[:country]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.put(:list, "gyms")
  end

  defp gym_position(%{cursor: cursor}, filters, operator_id) do
    case Cursor.decode(cursor, filters, operator_id) do
      {:ok, position} ->
        {:ok, position}

      :error ->
        {:error,
         {%{}, %{cursor: :string}}
         |> change()
         |> add_error(:cursor, "is invalid", validation: :format)}
    end
  end

  defp gym_position(_attrs, _filters, _operator_id), do: {:ok, nil}

  defp gym_detail(id) do
    case SimpleFit.Gyms.oversight_view(id) do
      nil ->
        nil

      gym ->
        owner =
          gym.owner_user_id &&
            %{
              user_id: gym.owner_user_id,
              short_name:
                get_in(Accounts.short_names([gym.owner_user_id]), [
                  gym.owner_user_id,
                  :short_name
                ])
            }

        gym |> Map.delete(:owner_user_id) |> Map.put(:owner, owner)
    end
  end

  defp profile_search(principal, attrs, kind) do
    with :ok <- profile_search_limit(principal) do
      found = profile_find(kind, attrs.query)
      results = if found, do: [profile_summary(kind, found)], else: []

      {:ok, %{profile_key(kind) => results}, {profile_target(kind), found},
       %{reason_code: attrs.reason_code}}
    end
  end

  defp profile_find(:fighter, "@" <> username),
    do: SimpleFit.Fighters.oversight_find({:username, username})

  defp profile_find(kind, query) do
    case Accounts.find_for_admin(query) do
      nil -> nil
      user_id -> profile_module(kind).oversight_find({:user, user_id})
    end
  end

  defp profile_detail(user, session, profile_id, params, ctx, kind) do
    with {:ok, attrs} <- user_query(params, [:reason_code], %{}),
         {:ok, id} <- user_id(profile_id) do
      project(profile_projection(kind), user, session, ctx, fn _principal ->
        read_profile(kind, id, attrs)
      end)
    end
  end

  defp read_gym(id, attrs),
    do: found(Overview.snapshot(fn -> gym_detail(id) end), {"gym", id}, attrs)

  defp read_profile(kind, id, attrs),
    do:
      found(
        Overview.snapshot(fn -> profile_view(kind, id) end),
        {profile_target(kind), id},
        attrs
      )

  # A read's answer: the record with its audit target and reason, or `not_found`.
  defp found(nil, _target, _attrs), do: {:error, :not_found}
  defp found(view, target, attrs), do: {:ok, view, target, %{reason_code: attrs.reason_code}}

  defp profile_summary(kind, id) do
    view = Overview.snapshot(fn -> profile_view(kind, id) end)

    view
    |> Map.take([:id, :user_id, :display_name, :profile_status, :account_status])
    |> Map.merge(%{
      username: Map.get(view, :username),
      brand_name: Map.get(view, :brand_name),
      active_relationships: view.relationships.active
    })
  end

  defp profile_view(kind, id) do
    case profile_module(kind).oversight_view(id) do
      nil ->
        nil

      view ->
        view
        |> Map.merge(%{
          account_status: Accounts.account_state(view.user_id).status,
          relationships: SimpleFit.Coaching.relationship_counts(kind, id)
        })
        |> Map.merge(profile_gyms(kind, view.user_id))
    end
  end

  defp profile_gyms(:coach, user_id), do: %{gyms: SimpleFit.Gyms.coach_affiliations(user_id)}

  defp profile_gyms(:fighter, user_id),
    do: %{gym_memberships: SimpleFit.Gyms.relationship_counts(user_id).member}

  defp profile_module(:coach), do: SimpleFit.Coaches
  defp profile_module(:fighter), do: SimpleFit.Fighters

  defp profile_key(:coach), do: :coaches
  defp profile_key(:fighter), do: :fighters

  defp profile_target(:coach), do: "coach_profile"
  defp profile_target(:fighter), do: "fighter_profile"

  defp profile_projection(:coach), do: "coaches.detail"
  defp profile_projection(:fighter), do: "fighters.detail"

  defp profile_search_limit(principal) do
    RateLimit.hit([
      {"operator_profile_search", :crypto.hash(:sha256, principal.user_id), @profile_search_limit,
       3600}
    ])
  end

  ## Overview (SF-121)

  @doc """
  The Control Plane overview (AD1): platform counts, review queue sizes and health
  checks, as one snapshot (`SimpleFit.Operators.Overview`). Needs an active operator
  with a current key check and at least one of `Overview.permissions/0`; each
  section shows only with its own permission and is `restricted` (no value)
  otherwise. Counts only, no names: reads aren't audited per load (SF-107),
  refusals are.

  `params`: `period` (`24h`, `7d` default, `30d`), for the "in period" counts.
  """
  @spec overview(User.t(), Session.t(), map(), ctx()) ::
          {:ok, Overview.t()} | {:error, error() | Ecto.Changeset.t()}
  def overview(%User{} = user, %Session{} = session, params, ctx \\ %{}) do
    started = System.monotonic_time()

    result =
      with {:ok, period} <- Overview.period(params),
           {:ok, principal} <- authorize(user, session, overview_permission(user), ctx) do
        granted = MapSet.new(active_permissions(principal.operator_id))
        {:ok, Overview.build(granted, period)}
      end

    :telemetry.execute(
      [:simple_fit, :admin_overview, :read],
      %{duration: System.monotonic_time() - started},
      %{outcome: overview_outcome(result)}
    )

    result
  end

  # The permission whose check (and refusal audit) stands for the overview: the
  # first of its permissions the operator holds, else the dashboard's own.
  defp overview_permission(user) do
    case usable_operator(user.id) do
      %Operator{id: id} ->
        Enum.find(Overview.permissions(), hd(Overview.permissions()), &granted?(id, &1))

      nil ->
        hd(Overview.permissions())
    end
  end

  defp overview_outcome({:ok, _}), do: :ok
  defp overview_outcome({:error, %Ecto.Changeset{}}), do: :invalid
  defp overview_outcome({:error, reason}), do: reason

  @doc "How many operators are active (the overview's operator count)."
  @spec active_count() :: non_neg_integer()
  def active_count, do: Repo.aggregate(from(o in Operator, where: o.status == :active), :count)

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
