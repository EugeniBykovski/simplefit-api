defmodule SimpleFit.Gyms.VerificationReview do
  @moduledoc """
  The operator side of gym business verification (SF-103; ADR 0026
  amendment SF-103): list and read submitted applications, download their
  documents, and decide.

  **No HTTP endpoint reaches this module.**

  **This module is the only boundary, and it trusts no name** (SF-136, SF-104
  F-03). Every public function, reads included, takes a credential and asks
  `SimpleFit.Gyms.VerificationAuthority` for the permission it needs, before
  touching anything and again once its locks are held. There is no way to pass an
  operator in: an address, an actor id or a hand-built principal is not a credential.

  **In production every call answers `:review_disabled`**, because SimpleFit has no
  authority that can prove an operator's identity until SF-110. No configuration can
  change that. The documents, decisions and revocations stay unreachable; owners
  keep drafting and submitting.

  Guards that hold under any authority:

    * the operator's user must not be the submitter, the application's or the
      gym's creator, an active staff member or a current member of the gym,
      checked by user id with the locks held: an owner cannot approve their own
      gym, and a staff change and a decision commit one after the other;
    * a decision names the revision the operator reviewed; any newer
      revision is a conflict;
    * only the reviewed transitions exist (`submitted -> approved |
      rejected | changes_requested`, `approved -> revoked`), with a reason
      code from `SimpleFit.Gyms.VerificationPolicy` where one is needed;
    * concurrent decisions serialize on the application row: exactly one
      wins, the others get a conflict.

  Approval changes nothing else: no Stripe object, plan, entitlement,
  publication or staff right follows from it. A revocation keeps the gym,
  its staff, members, classes, bookings, attendance and payments as they
  are.

  **Revocation:** the authority is asked on every call, and again after the locks
  are held, so a call that waited on a lock can't act on an old answer. A decision
  that passed that second check before the revocation took effect stands, and is in
  the history; nothing is rewritten.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.{Clock, Repo, Storage}

  alias SimpleFit.Gyms.{
    Access,
    Gym,
    Member,
    OperatorPrincipal,
    StaffMembership,
    Verification,
    VerificationApplication,
    VerificationAuthority,
    VerificationEvent,
    VerificationEvidence,
    VerificationPolicy
  }

  @unlogged [log: false]
  @download_expires_in 300

  @audit %{
    approved: :business_verification_approved,
    rejected: :business_verification_rejected,
    changes_requested: :business_verification_changes_requested,
    revoked: :business_verification_revoked
  }

  @type summary :: %{
          application: VerificationApplication.t(),
          gym_name: String.t()
        }

  @type detail :: %{
          application: VerificationApplication.t(),
          gym: Gym.t(),
          evidence: [VerificationEvidence.t()],
          events: [VerificationEvent.t()]
        }

  @type error ::
          :not_found
          | VerificationAuthority.error()
          | {:conflict, map()}
          | {:invalid, atom()}

  @doc """
  Submitted applications awaiting a decision, oldest first, leaving out any this
  operator has an interest in.
  """
  @spec list_submitted(term()) :: {:ok, [summary()]} | {:error, error()}
  def list_submitted(credential) do
    with {:ok, operator} <- authorize(credential, :read_queue) do
      {:ok, Enum.filter(submitted(), &(independent(&1.application, operator) == :ok))}
    end
  end

  defp submitted do
    Repo.all(
      from(a in VerificationApplication,
        join: g in Gym,
        on: g.id == a.gym_id,
        where: a.status == :submitted,
        order_by: [asc: a.submitted_at, asc: a.id],
        select: %{application: a, gym_name: g.name}
      ),
      @unlogged
    )
  end

  @doc "One application with its gym, every document and its history (an independent operator only)."
  @spec show(term(), term()) :: {:ok, detail()} | {:error, error()}
  def show(application_id, credential) do
    with {:ok, operator} <- authorize(credential, :read_application),
         {:ok, application} <- fetch(application_id),
         :ok <- independent(application, operator) do
      {:ok,
       %{
         application: application,
         gym: Repo.get!(Gym, application.gym_id, @unlogged),
         evidence:
           Repo.all(
             from(e in VerificationEvidence,
               where: e.application_id == ^application.id,
               order_by: [asc: e.inserted_at, asc: e.id]
             ),
             @unlogged
           ),
         events:
           Repo.all(
             from(e in VerificationEvent,
               where: e.application_id == ^application.id,
               order_by: [asc: e.seq]
             ),
             @unlogged
           )
       }}
    end
  end

  @doc """
  A short-lived (5 minutes) presigned download of a confirmed document of a
  submitted, decided or revoked application; recorded in the history before
  the URL is returned.
  """
  @spec evidence_download(term(), term(), term()) ::
          {:ok, Storage.Presigned.t()} | {:error, error() | SimpleFit.Provider.error()}
  def evidence_download(application_id, evidence_id, credential) do
    Repo.transaction(fn ->
      with {:ok, _} <- authorize(credential, :read_evidence),
           {:ok, application} <- lock(application_id, :share),
           {:ok, operator} <- authorize(credential, :read_evidence),
           :ok <- independent(application, operator),
           :ok <- reviewable(application),
           {:ok, evidence} <- uploaded_evidence(application, evidence_id),
           {:ok, download} <-
             Storage.presign_download(evidence.object_key, expires_in: @download_expires_in) do
        Verification.record_event!(
          application,
          :evidence_downloaded,
          Map.put(attribution(operator), :evidence_ids, [evidence.id]),
          now()
        )

        download
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Decides a submitted application at the reviewed `:revision`:
  `:approved`, `:rejected` or `:changes_requested` (the last two with a
  `:reason` code). Options: `:revision` and `:credential` (both required),
  `:reason`.
  """
  @spec decide(term(), :approved | :rejected | :changes_requested, keyword()) ::
          {:ok, VerificationApplication.t()} | {:error, error()}
  def decide(application_id, decision, opts)
      when decision in [:approved, :rejected, :changes_requested] do
    transact(application_id, decision_permission(decision), opts, fn application, operator ->
      with :ok <- status(application, :submitted),
           :ok <- reviewed(application, opts),
           {:ok, reason} <- reason(decision, opts),
           {:ok, evidence_ids} <- submitted_evidence(application) do
        commit(application, decision, reason, operator, evidence_ids)
      end
    end)
  end

  @doc """
  Revokes an approved application with a `:reason` code. Options:
  `:reason` and `:credential` (both required).
  """
  @spec revoke(term(), keyword()) :: {:ok, VerificationApplication.t()} | {:error, error()}
  def revoke(application_id, opts) do
    transact(application_id, :revoke, opts, fn application, operator ->
      with :ok <- status(application, :approved),
           {:ok, reason} <- reason(:revoked, opts),
           {:ok, evidence_ids} <- submitted_evidence(application) do
        commit(application, :revoked, reason, operator, evidence_ids)
      end
    end)
  end

  ## Internals

  defp transact(application_id, permission, opts, fun) do
    credential = Keyword.get(opts, :credential)

    Repo.transaction(fn ->
      with {:ok, _} <- authorize(credential, permission),
           {:ok, application} <- lock(application_id, :update),
           # Asked again with the locks held: waiting on one never acts on an old answer.
           {:ok, operator} <- authorize(credential, permission),
           :ok <- independent(application, operator),
           {:ok, application} <- fun.(application, operator) do
        application
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp decision_permission(:approved), do: :approve
  defp decision_permission(:rejected), do: :reject
  defp decision_permission(:changes_requested), do: :request_changes

  # The one door. Refusals are counted, without saying who or what was tried.
  defp authorize(credential, permission) do
    case VerificationAuthority.authenticate(credential, permission) do
      {:ok, %OperatorPrincipal{}} = allowed ->
        allowed

      {:error, reason} = refused ->
        :telemetry.execute([:simple_fit, :gyms, :verification, :review_refused], %{count: 1}, %{
          reason: reason
        })

        refused
    end
  end

  defp attribution(%OperatorPrincipal{} = operator) do
    %{
      operator_actor_id: operator.actor_id,
      operator_authority: operator.authority,
      operation_id: Ecto.UUID.generate()
    }
  end

  defp commit(application, decision, reason, operator, evidence_ids) do
    now = now()

    application =
      application
      |> Changeset.change(status: decision, decided_at: now)
      |> Repo.update!(@unlogged)

    Verification.record_event!(
      application,
      decision,
      Map.merge(attribution(operator), %{reason_code: reason, evidence_ids: evidence_ids}),
      now
    )

    Verification.audit!(application, Map.fetch!(@audit, decision), nil, now)

    :telemetry.execute([:simple_fit, :gyms, :verification, :decided], %{count: 1}, %{
      decision: decision
    })

    {:ok, application}
  end

  # The gym row first (share), then the application: the order of every
  # owner write (`Guarded` locks the gym row for update), so an owner change
  # and a decision commit one after the other.
  defp lock(application_id, mode) do
    with {:ok, application} <- fetch(application_id),
         :ok <- Access.lock_gym_shared(application.gym_id) do
      query = from(a in VerificationApplication, where: a.id == ^application.id)

      query =
        if mode == :update,
          do: from(a in query, lock: "FOR UPDATE"),
          else: from(a in query, lock: "FOR SHARE")

      {:ok, Repo.one!(query, @unlogged)}
    end
  end

  defp fetch(application_id) do
    with {:ok, id} <- cast(application_id),
         %VerificationApplication{} = application <-
           Repo.get(VerificationApplication, id, @unlogged) do
      {:ok, application}
    else
      _ -> {:error, :not_found}
    end
  end

  # The operator's user has no interest in the application, by user id: not its
  # creator or submitter, not the gym's creator, none of its active staff or
  # current members. Called with the gym row locked, so a staff or member change
  # commits either before this check or after the decision.
  defp independent(application, %OperatorPrincipal{user_id: user_id}) do
    gym_id = application.gym_id

    if user_id in [application.created_by_user_id, application.submitted_by_user_id] or
         gym_creator?(gym_id, user_id) or staff?(gym_id, user_id) or member?(gym_id, user_id),
       do: {:error, {:conflict, %{operator: "not_independent"}}},
       else: :ok
  end

  defp gym_creator?(gym_id, user_id),
    do: exists?(from(g in Gym, where: g.id == ^gym_id and g.created_by_user_id == ^user_id))

  defp staff?(gym_id, user_id) do
    exists?(
      from(m in StaffMembership,
        where: m.gym_id == ^gym_id and m.user_id == ^user_id and m.status == :active
      )
    )
  end

  defp member?(gym_id, user_id) do
    exists?(
      from(m in Member,
        where: m.gym_id == ^gym_id and m.user_id == ^user_id and m.status in [:requested, :active]
      )
    )
  end

  defp exists?(query), do: Repo.exists?(query, @unlogged)

  defp status(%VerificationApplication{status: status}, status), do: :ok

  defp status(application, _expected),
    do: {:error, {:conflict, %{verification: Atom.to_string(application.status)}}}

  defp reviewable(%VerificationApplication{status: status})
       when status in [:submitted, :changes_requested, :approved, :rejected, :revoked],
       do: :ok

  defp reviewable(_application), do: {:error, {:conflict, %{verification: "draft"}}}

  defp reviewed(application, opts) do
    case Keyword.get(opts, :revision) do
      revision when revision == application.revision -> :ok
      revision when is_integer(revision) -> {:error, {:conflict, %{revision: "stale"}}}
      _missing -> {:error, {:invalid, :revision}}
    end
  end

  defp reason(:approved, opts) do
    if Keyword.get(opts, :reason) in [nil, ""],
      do: {:ok, nil},
      else: {:error, {:invalid, :reason}}
  end

  defp reason(decision, opts) do
    allowed = Enum.map(VerificationPolicy.reasons(decision), &Atom.to_string/1)
    reason = Keyword.get(opts, :reason)
    if reason in allowed, do: {:ok, reason}, else: {:error, {:invalid, :reason}}
  end

  # The confirmed documents that were part of a submission of this
  # application (never another application's).
  defp submitted_evidence(application) do
    ids =
      Repo.all(
        from(e in VerificationEvidence,
          where:
            e.application_id == ^application.id and e.status == :uploaded and
              not is_nil(e.submitted_revision),
          order_by: [asc: e.inserted_at, asc: e.id],
          select: e.id
        ),
        @unlogged
      )

    if length(ids) >= VerificationPolicy.min_evidence(),
      do: {:ok, ids},
      else: {:error, {:conflict, %{evidence: "missing"}}}
  end

  defp uploaded_evidence(application, evidence_id) do
    with {:ok, id} <- cast(evidence_id),
         %VerificationEvidence{status: :uploaded} = evidence <-
           Repo.one(
             from(e in VerificationEvidence,
               where: e.id == ^id and e.application_id == ^application.id
             ),
             @unlogged
           ) do
      {:ok, evidence}
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast(_id), do: :error

  defp now do
    %DateTime{microsecond: {us, _}} = at = Clock.utc_now()
    %{at | microsecond: {us, 6}}
  end
end
