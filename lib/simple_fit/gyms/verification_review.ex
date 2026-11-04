defmodule SimpleFit.Gyms.VerificationReview do
  @moduledoc """
  The operator side of gym business verification (SF-103; ADR 0026
  amendment SF-103): list and read submitted applications, download their
  documents, and decide.

  **No HTTP endpoint reaches this module.** SimpleFit has no platform
  operator identity or admin authorization domain yet (the designed admin
  console, AD0–AD20, has no backend), so review follows the existing
  operator pattern (`SimpleFit.Billing.Operations`, SF-101/SF-102): people
  with production shell access run `mix gyms.verification`, and that access
  is the authorization boundary. Each write names the operator (an email
  address) and is recorded in the application's append-only history with
  the revision and documents it covered.

  Guards that hold whatever the shell user types:

    * the operator must not be the submitter, the application's creator or
      an active staff member of the gym (matched on their verified email
      identities): an owner cannot approve their own gym through this path;
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
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.{EmailAddress, Identity}
  alias SimpleFit.{Clock, Repo, Storage}

  alias SimpleFit.Gyms.{
    Access,
    Gym,
    StaffMembership,
    Verification,
    VerificationApplication,
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

  @type error :: :not_found | {:conflict, map()} | {:invalid, atom()}

  @doc "Submitted applications awaiting a decision, oldest first."
  @spec list_submitted() :: [summary()]
  def list_submitted do
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

  @doc "One application with its gym, every document and its history."
  @spec show(term()) :: {:ok, detail()} | {:error, :not_found}
  def show(application_id) do
    with {:ok, application} <- fetch(application_id) do
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
  submitted, decided or revoked application, for `operator`; recorded in
  the history before the URL is returned.
  """
  @spec evidence_download(term(), term(), String.t()) ::
          {:ok, Storage.Presigned.t()} | {:error, error() | SimpleFit.Provider.error()}
  def evidence_download(application_id, evidence_id, operator) do
    Repo.transaction(fn ->
      with {:ok, operator} <- operator(operator),
           {:ok, application} <- lock(application_id, :share),
           :ok <- independent(application, operator),
           :ok <- reviewable(application),
           {:ok, evidence} <- uploaded_evidence(application, evidence_id),
           {:ok, download} <-
             Storage.presign_download(evidence.object_key, expires_in: @download_expires_in) do
        Verification.record_event!(
          application,
          :evidence_downloaded,
          %{operator: operator, evidence_ids: [evidence.id]},
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
  `:reason` code). Options: `:revision` (required), `:reason`,
  `:operator` (required, an email address).
  """
  @spec decide(term(), :approved | :rejected | :changes_requested, keyword()) ::
          {:ok, VerificationApplication.t()} | {:error, error()}
  def decide(application_id, decision, opts)
      when decision in [:approved, :rejected, :changes_requested] do
    transact(application_id, opts, fn application, operator ->
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
  `:reason` and `:operator` (both required).
  """
  @spec revoke(term(), keyword()) :: {:ok, VerificationApplication.t()} | {:error, error()}
  def revoke(application_id, opts) do
    transact(application_id, opts, fn application, operator ->
      with :ok <- status(application, :approved),
           {:ok, reason} <- reason(:revoked, opts),
           {:ok, evidence_ids} <- submitted_evidence(application) do
        commit(application, :revoked, reason, operator, evidence_ids)
      end
    end)
  end

  ## Internals

  defp transact(application_id, opts, fun) do
    Repo.transaction(fn ->
      with {:ok, operator} <- operator(Keyword.get(opts, :operator)),
           {:ok, application} <- lock(application_id, :update),
           :ok <- independent(application, operator),
           {:ok, application} <- fun.(application, operator) do
        application
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
      %{operator: operator, reason_code: reason, evidence_ids: evidence_ids},
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

  defp operator(value) when is_binary(value) do
    case EmailAddress.normalize(value) do
      {:ok, email} -> {:ok, email}
      :error -> {:error, {:invalid, :operator}}
    end
  end

  defp operator(_value), do: {:error, {:invalid, :operator}}

  # The operator is none of the gym's active staff and neither the
  # application's creator nor its submitter (by verified email identity).
  defp independent(application, operator) do
    people =
      Enum.reject([application.created_by_user_id, application.submitted_by_user_id], &is_nil/1)

    conflicted? =
      Repo.exists?(
        from(i in Identity,
          left_join: m in StaffMembership,
          on: m.user_id == i.user_id and m.gym_id == ^application.gym_id and m.status == :active,
          where:
            i.provider == :email and i.provider_subject == ^operator and
              (not is_nil(m.id) or i.user_id in ^people)
        ),
        @unlogged
      )

    if conflicted?, do: {:error, {:conflict, %{operator: "not_independent"}}}, else: :ok
  end

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
