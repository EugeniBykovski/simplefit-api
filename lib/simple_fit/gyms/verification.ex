defmodule SimpleFit.Gyms.Verification do
  @moduledoc """
  Gym business verification, the owner's side (SF-103, OG7; ADR 0026
  amendment SF-103). Internal to `SimpleFit.Gyms`.

  The owner (`manage_business_verification`; nobody else, not a manager)
  drafts an application with the business details, uploads documents to
  private storage and submits it. Only an operator decides
  (`SimpleFit.Gyms.VerificationReview`, no HTTP endpoint): no owner
  request, field or role approves, rejects or revokes anything, and no
  other fact (gym setup, a SimpleFit plan, a payment, Stripe Connect
  capabilities) counts as verification.

  ## Lifecycle

      draft --submit--> submitted --operator--> approved --operator--> revoked
                          |    \\--operator--> rejected
                          \\--operator--> changes_requested --submit--> submitted

  At most one current application per gym (`draft`, `submitted`,
  `changes_requested`, `approved`). After a rejection or a revocation the
  owner starts a new application from nothing: documents belong to one
  application and never validate another.

  ## Revisions

  Every owner change (details, a document added, confirmed or removed)
  bumps the application's `revision`, and each change names the revision
  it was made on: a stale form (another tab, another device) gets a
  conflict instead of overwriting newer details or documents. Submitting
  the revision that is already submitted returns the same state.

  ## Documents

  A document is announced first (kind, file name, content type, exact
  size, within `SimpleFit.Gyms.VerificationPolicy`) and the server answers
  with a presigned upload to a key it built. The client uploads directly to
  storage, then asks the server to confirm: the server reads the object's
  size and type from storage itself and attaches the document only when
  they match. Client-supplied keys, URLs or paths are never accepted.
  Uploads never confirmed and documents removed before submission are
  deleted from storage by `SimpleFit.Gyms.VerificationCleanupWorker`;
  submitted documents are frozen and kept (no retention period is
  approved).

  ## Locks

  Writes run in `SimpleFit.Gyms.Guarded` (session, gym row and the actor's
  membership, the SF-83 order), then lock the application row; operator
  decisions take the gym row (share) and then the application, so an owner
  change and a decision commit one after the other.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.{Clock, Repo, Storage}

  alias SimpleFit.Gyms.{
    Access,
    Audit,
    Guarded,
    Members,
    VerificationApplication,
    VerificationEvent,
    VerificationEvidence,
    VerificationPolicy
  }

  alias SimpleFit.Storage.ObjectKey

  @unlogged [log: false]
  @limit {"gym_verification", 60, 600}
  @upload_expires_in 900

  @type decision :: %{
          decision: VerificationPolicy.decision(),
          reason_code: String.t() | nil,
          decided_at: DateTime.t()
        }

  @type view :: %{
          gym_id: Ecto.UUID.t(),
          status: :not_started | VerificationApplication.status(),
          application: VerificationApplication.t() | nil,
          evidence: [VerificationEvidence.t()],
          latest_decision: decision() | nil,
          missing: [atom()],
          can_edit: boolean(),
          can_submit: boolean(),
          requirements: requirements()
        }

  @type requirements :: %{
          policy_version: String.t(),
          required_fields: [atom()],
          min_evidence: pos_integer(),
          max_evidence: pos_integer(),
          max_bytes: pos_integer(),
          content_types: [String.t()],
          kinds: [atom()]
        }

  @type error ::
          :not_found
          | :forbidden
          | :session_revoked
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | Changeset.t()
          | SimpleFit.Provider.error()

  ## Reads

  @doc "The gym's verification, for its owner."
  @spec get(User.t(), term()) :: {:ok, view()} | {:error, :not_found | :forbidden}
  def get(%User{} = user, gym_id) do
    with {:ok, %{gym: gym}} <- Access.authorize(user, gym_id, :manage_business_verification) do
      {:ok, view(gym.id, latest(gym.id))}
    end
  end

  @doc """
  Whether the gym's business verification is approved now (read by the
  go-live evaluator): the current application's status, or `:not_started`.
  """
  @spec status(Ecto.UUID.t()) :: :not_started | VerificationApplication.status()
  def status(gym_id) do
    case latest(gym_id) do
      nil -> :not_started
      %VerificationApplication{status: status} -> status
    end
  end

  ## Owner writes

  @doc """
  Creates the gym's draft (no current application: `revision` absent) or
  changes the details of the current one (`revision` = its revision, and it
  is a draft or has changes requested). `{:ok, {view, :created | :updated}}`.
  """
  @spec save(User.t(), Session.t(), term(), map()) ::
          {:ok, {view(), :created | :updated}} | {:error, error()}
  def save(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    write(user, session, gym_id, fn %{gym: gym} ->
      with {:ok, expected, details} <- split_revision(attrs),
           :ok <- known_fields(details, VerificationPolicy.fields()) do
        upsert(lock_current(gym.id), gym.id, user, expected, details)
      end
    end)
  end

  @doc """
  Submits the current application at `revision` for review. Requires the
  policy's fields and at least one confirmed document, and no upload still
  pending. Submitting a revision that is already submitted returns it.
  """
  @spec submit(User.t(), Session.t(), term(), map()) :: {:ok, view()} | {:error, error()}
  def submit(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    write(user, session, gym_id, fn %{gym: gym} ->
      with {:ok, expected, rest} <- split_revision(attrs),
           :ok <- known_fields(rest, []),
           {:ok, application} <- current(gym.id) do
        do_submit(application, expected, user)
      end
    end)
  end

  @doc """
  Announces a document of the current (editable) application at `revision`:
  `kind`, `file_name`, `content_type` and `byte_size`. Returns the view, the
  pending document and a presigned upload (`PUT`, 15 minutes) that only
  accepts exactly that type and size.
  """
  @spec add_evidence(User.t(), Session.t(), term(), map()) ::
          {:ok, {view(), VerificationEvidence.t(), Storage.Presigned.t()}} | {:error, error()}
  def add_evidence(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    write(user, session, gym_id, fn %{gym: gym} ->
      with {:ok, expected, rest} <- split_revision(attrs),
           {:ok, document} <- document(rest),
           {:ok, application} <- editable(gym.id, expected),
           :ok <- below_limit(application) do
        announce(application, document, user)
      end
    end)
  end

  @doc """
  Attaches an uploaded document after the server has read its size and
  type from storage. Confirming an attached document again returns the
  view; a missing or different object is a conflict and attaches nothing.
  """
  @spec confirm_evidence(User.t(), Session.t(), term(), term()) ::
          {:ok, view()} | {:error, error()}
  def confirm_evidence(%User{} = user, %Session{} = session, gym_id, evidence_id) do
    # The storage call happens before the write transaction, so no lock is
    # held while it runs; the transaction then re-reads everything.
    with {:ok, %{gym: gym}} <- Access.authorize(user, gym_id, :manage_business_verification),
         {:ok, evidence} <- fetch_evidence(gym.id, evidence_id),
         {:ok, seen} <- observe(evidence) do
      write(user, session, gym.id, &confirm_locked(&1.gym, evidence.id, seen))
    end
  end

  defp confirm_locked(gym, evidence_id, seen) do
    with {:ok, application} <- current(gym.id),
         {:ok, evidence} <- lock_evidence(application, evidence_id) do
      attach(application, evidence, seen)
    end
  end

  @doc """
  Removes a document of the current (editable) application at `revision`
  that was never part of a submission. Removing it again returns the view.
  """
  @spec remove_evidence(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, view()} | {:error, error()}
  def remove_evidence(%User{} = user, %Session{} = session, gym_id, evidence_id, attrs)
      when is_map(attrs) do
    write(user, session, gym_id, fn %{gym: gym} ->
      with {:ok, expected, rest} <- split_revision(attrs),
           :ok <- known_fields(rest, []),
           {:ok, application} <- editable(gym.id, expected),
           {:ok, evidence} <- lock_evidence(application, evidence_id) do
        remove(application, evidence)
      end
    end)
  end

  ## Views

  @doc false
  @spec view(Ecto.UUID.t(), VerificationApplication.t() | nil) :: view()
  def view(gym_id, nil) do
    %{
      gym_id: gym_id,
      status: :not_started,
      application: nil,
      evidence: [],
      latest_decision: nil,
      missing: VerificationPolicy.required_fields(nil) ++ [:evidence],
      can_edit: true,
      can_submit: false,
      requirements: requirements(nil)
    }
  end

  def view(gym_id, %VerificationApplication{} = application) do
    evidence = evidence_of(application.id)
    editable? = VerificationApplication.editable?(application)
    missing = missing(application, evidence)

    %{
      gym_id: gym_id,
      status: application.status,
      application: application,
      evidence: evidence,
      latest_decision: latest_decision(application.id),
      missing: missing,
      # A rejected or revoked application is history: editing starts a new one.
      can_edit: editable? or application.status in [:rejected, :revoked],
      can_submit:
        editable? and missing == [] and not Enum.any?(evidence, &(&1.status == :pending_upload)),
      requirements: requirements(application)
    }
  end

  # A rejected or revoked application is history: the next one starts under
  # the current policy, with no country yet.
  defp requirements(application) do
    {version, country} =
      case application do
        %VerificationApplication{status: status} = a when status not in [:rejected, :revoked] ->
          {a.policy_version, a.registration_country}

        _none_or_history ->
          {VerificationPolicy.version(), nil}
      end

    %{
      policy_version: version,
      required_fields: VerificationPolicy.required_fields(country),
      min_evidence: VerificationPolicy.min_evidence(),
      max_evidence: VerificationPolicy.max_evidence(),
      max_bytes: VerificationPolicy.max_bytes(),
      content_types: VerificationPolicy.content_types(),
      kinds: VerificationPolicy.kinds()
    }
  end

  ## Internals

  defp write(user, session, gym_id, fun) do
    Guarded.write(user, session, gym_id, :manage_business_verification, @limit, fun)
  end

  defp upsert(nil, gym_id, user, expected, details), do: create(gym_id, user, expected, details)

  defp upsert(application, _gym_id, _user, expected, details),
    do: update(application, expected, details)

  defp create(gym_id, user, nil, details) do
    now = now()

    changeset =
      %VerificationApplication{
        gym_id: gym_id,
        status: :draft,
        revision: 1,
        policy_version: VerificationPolicy.version(),
        created_by_user_id: user.id
      }
      |> VerificationApplication.details_changeset(details)
      # A new application starts at revision 1 whatever it holds.
      |> Changeset.put_change(:revision, 1)
      |> Changeset.put_change(:inserted_at, now)
      |> Changeset.put_change(:updated_at, now)

    with {:ok, application} <- Repo.insert(changeset, @unlogged) do
      {:ok, {view(gym_id, application), :created}}
    end
  end

  defp create(_gym_id, _user, _expected, _details), do: stale(nil)

  defp update(%VerificationApplication{} = application, expected, details) do
    with :ok <- fresh(application, expected),
         :ok <- editable_status(application),
         {:ok, application} <-
           application
           |> VerificationApplication.details_changeset(details)
           |> Repo.update(@unlogged) do
      {:ok, {view(application.gym_id, application), :updated}}
    end
  end

  defp do_submit(%VerificationApplication{status: :submitted} = application, expected, _user)
       when application.submitted_revision == expected,
       do: {:ok, view(application.gym_id, application)}

  defp do_submit(application, expected, user) do
    with :ok <- fresh(application, expected),
         :ok <- editable_status(application) do
      evidence = lock_live_evidence(application.id)
      uploaded = Enum.filter(evidence, &(&1.status == :uploaded))

      cond do
        Enum.any?(evidence, &(&1.status == :pending_upload)) ->
          {:error, {:conflict, %{evidence: "upload_pending"}}}

        (missing = missing(application, evidence)) != [] ->
          {:error, incomplete(application, missing)}

        true ->
          submitted(application, uploaded, user)
      end
    end
  end

  defp submitted(application, uploaded, user) do
    now = now()

    application =
      application
      |> Changeset.change(
        status: :submitted,
        submitted_at: now,
        submitted_revision: application.revision,
        submitted_by_user_id: user.id
      )
      |> Repo.update!(@unlogged)

    ids = Enum.map(uploaded, & &1.id)

    Repo.update_all(
      from(e in VerificationEvidence, where: e.id in ^ids and is_nil(e.submitted_revision)),
      [set: [submitted_revision: application.revision, updated_at: now]],
      @unlogged
    )

    record_event!(application, :submitted, %{actor_user_id: user.id, evidence_ids: ids}, now)
    audit!(application, :business_verification_submitted, user.id, now)
    {:ok, view(application.gym_id, application)}
  end

  defp announce(application, document, user) do
    now = now()
    id = Ecto.UUID.generate()

    with {:ok, key} <-
           ObjectKey.build([
             "gyms",
             application.gym_id,
             "business-verification",
             application.id,
             id
           ]),
         {:ok, upload} <-
           Storage.presign_upload(key,
             content_type: document.content_type,
             content_length: document.byte_size,
             expires_in: @upload_expires_in
           ) do
      evidence =
        Repo.insert!(
          %VerificationEvidence{
            id: id,
            gym_id: application.gym_id,
            application_id: application.id,
            kind: document.kind,
            status: :pending_upload,
            object_key: key,
            content_type: document.content_type,
            byte_size: document.byte_size,
            file_name: document.file_name,
            created_by_user_id: user.id,
            upload_expires_at: usec(upload.expires_at),
            inserted_at: now,
            updated_at: now
          },
          @unlogged
        )

      application = bump!(application)
      {:ok, {view(application.gym_id, application), evidence, upload}}
    end
  end

  defp observe(%VerificationEvidence{status: :pending_upload} = evidence) do
    case Storage.stat(evidence.object_key) do
      {:ok, seen} -> {:ok, seen}
      {:error, :not_found} -> {:error, {:conflict, %{upload: "not_found"}}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Already attached or removed: the transaction answers (no storage call).
  defp observe(%VerificationEvidence{}), do: {:ok, nil}

  defp attach(application, %VerificationEvidence{status: :uploaded}, _seen),
    do: {:ok, view(application.gym_id, application)}

  defp attach(_application, %VerificationEvidence{status: :removed}, _seen),
    do: {:error, {:conflict, %{evidence: "removed"}}}

  defp attach(_application, %VerificationEvidence{}, nil),
    do: {:error, {:conflict, %{upload: "not_found"}}}

  defp attach(application, %VerificationEvidence{} = evidence, seen) do
    with :ok <- editable_status(application) do
      if seen.content_length == evidence.byte_size and
           media_type(seen.content_type) == evidence.content_type do
        evidence
        |> Changeset.change(status: :uploaded, uploaded_at: now())
        |> Repo.update!(@unlogged)

        application = bump!(application)
        {:ok, view(application.gym_id, application)}
      else
        {:error, {:conflict, %{upload: "mismatch"}}}
      end
    end
  end

  defp remove(application, %VerificationEvidence{status: :removed}),
    do: {:ok, view(application.gym_id, application)}

  defp remove(_application, %VerificationEvidence{submitted_revision: revision})
       when is_integer(revision),
       do: {:error, {:conflict, %{evidence: "submitted"}}}

  defp remove(application, evidence) do
    evidence
    |> Changeset.change(status: :removed, removed_at: now())
    |> Repo.update!(@unlogged)

    application = bump!(application)
    {:ok, view(application.gym_id, application)}
  end

  defp bump!(application),
    do:
      application
      |> Changeset.change(revision: application.revision + 1)
      |> Repo.update!(@unlogged)

  # The fields the policy requires that are blank, plus `:evidence` without
  # enough confirmed documents.
  defp missing(application, evidence) do
    fields =
      application.registration_country
      |> VerificationPolicy.required_fields()
      |> Enum.filter(&is_nil(Map.get(application, &1)))

    uploaded = Enum.count(evidence, &(&1.status == :uploaded))
    if uploaded < VerificationPolicy.min_evidence(), do: fields ++ [:evidence], else: fields
  end

  defp incomplete(application, missing) do
    Enum.reduce(missing, Changeset.change(application), fn
      :evidence, changeset ->
        Changeset.add_error(changeset, :evidence, "should have at least %{count} item(s)",
          count: VerificationPolicy.min_evidence(),
          validation: :length,
          kind: :min,
          type: :list
        )

      field, changeset ->
        Changeset.add_error(changeset, field, "can't be blank", validation: :required)
    end)
  end

  defp split_revision(attrs) do
    case Map.pop(attrs, "revision") do
      {nil, rest} -> {:ok, nil, rest}
      {revision, rest} when is_integer(revision) and revision >= 1 -> {:ok, revision, rest}
      {_invalid, _rest} -> {:error, field_error(:revision, "is invalid", validation: :cast)}
    end
  end

  defp known_fields(attrs, allowed) do
    allowed = Enum.map(allowed, &Atom.to_string/1)

    case Members.reject_unknown_fields(Changeset.change({%{}, %{}}), attrs, allowed) do
      %Changeset{valid?: true} -> :ok
      changeset -> {:error, changeset}
    end
  end

  defp field_error(field, message, keys) do
    {%{}, %{}}
    |> Changeset.change()
    |> Changeset.add_error(field, message, keys)
  end

  @document_types %{
    kind: :string,
    file_name: :string,
    content_type: :string,
    byte_size: :integer
  }

  defp document(attrs) do
    with :ok <- known_fields(attrs, Map.keys(@document_types)) do
      changeset =
        {%{}, @document_types}
        |> Changeset.cast(attrs, Map.keys(@document_types))
        |> Changeset.validate_required(Map.keys(@document_types))
        |> Changeset.validate_inclusion(
          :kind,
          Enum.map(VerificationPolicy.kinds(), &Atom.to_string/1)
        )
        |> Changeset.validate_inclusion(:content_type, VerificationPolicy.content_types())
        |> Changeset.validate_number(:byte_size,
          greater_than: 0,
          less_than_or_equal_to: VerificationPolicy.max_bytes()
        )
        |> Changeset.update_change(:file_name, &file_name/1)
        |> Changeset.validate_length(:file_name, min: 1, max: 120, count: :codepoints)

      case Changeset.apply_action(changeset, :insert) do
        {:ok, document} ->
          {:ok, %{document | kind: String.to_existing_atom(document.kind)}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # The base name only, without control characters or path separators.
  defp file_name(value) when is_binary(value) do
    value
    |> String.split(["/", "\\"])
    |> List.last()
    |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "")
    |> String.trim()
  end

  defp file_name(value), do: value

  defp media_type(nil), do: nil

  defp media_type(content_type),
    do: content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

  defp below_limit(application) do
    live =
      Repo.aggregate(
        from(e in VerificationEvidence,
          where: e.application_id == ^application.id and e.status != :removed
        ),
        :count,
        @unlogged
      )

    if live < VerificationPolicy.max_evidence(),
      do: :ok,
      else: {:error, {:conflict, %{evidence: "limit_reached"}}}
  end

  defp current(gym_id) do
    case lock_current(gym_id) do
      nil -> {:error, {:conflict, %{verification: "not_started"}}}
      application -> {:ok, application}
    end
  end

  defp editable(gym_id, expected) do
    with {:ok, application} <- current(gym_id),
         :ok <- fresh(application, expected),
         :ok <- editable_status(application) do
      {:ok, application}
    end
  end

  defp fresh(%VerificationApplication{revision: revision}, revision), do: :ok
  defp fresh(application, _expected), do: stale(application)

  defp stale(nil), do: {:error, {:conflict, %{revision: "stale"}}}

  defp stale(%VerificationApplication{revision: revision}),
    do: {:error, {:conflict, %{revision: "stale", current_revision: revision}}}

  defp editable_status(application) do
    if VerificationApplication.editable?(application),
      do: :ok,
      else: {:error, {:conflict, %{verification: Atom.to_string(application.status)}}}
  end

  defp lock_current(gym_id) do
    Repo.one(
      from(a in VerificationApplication,
        where:
          a.gym_id == ^gym_id and a.status in [:draft, :submitted, :changes_requested, :approved],
        lock: "FOR UPDATE"
      ),
      @unlogged
    )
  end

  # The current application, or the latest ended one (history).
  defp latest(gym_id) do
    Repo.one(
      from(a in VerificationApplication,
        where: a.gym_id == ^gym_id,
        order_by: [
          desc: a.status in [:draft, :submitted, :changes_requested, :approved],
          desc: a.inserted_at,
          desc: a.id
        ],
        limit: 1
      ),
      @unlogged
    )
  end

  defp fetch_evidence(gym_id, evidence_id) do
    with {:ok, id} <- cast(evidence_id),
         %VerificationEvidence{} = evidence <-
           Repo.one(
             from(e in VerificationEvidence, where: e.id == ^id and e.gym_id == ^gym_id),
             @unlogged
           ) do
      {:ok, evidence}
    else
      _ -> {:error, :not_found}
    end
  end

  # Another application's document (an older one of this gym included) is
  # `not_found`: documents never cross applications.
  defp lock_evidence(application, evidence_id) do
    with {:ok, id} <- cast(evidence_id),
         %VerificationEvidence{} = evidence <-
           Repo.one(
             from(e in VerificationEvidence,
               where: e.id == ^id and e.application_id == ^application.id,
               lock: "FOR UPDATE"
             ),
             @unlogged
           ) do
      {:ok, evidence}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_live_evidence(application_id) do
    Repo.all(
      from(e in VerificationEvidence,
        where: e.application_id == ^application_id and e.status != :removed,
        order_by: [asc: e.inserted_at, asc: e.id],
        lock: "FOR UPDATE"
      ),
      @unlogged
    )
  end

  defp evidence_of(application_id) do
    Repo.all(
      from(e in VerificationEvidence,
        where: e.application_id == ^application_id and e.status != :removed,
        order_by: [asc: e.inserted_at, asc: e.id]
      ),
      @unlogged
    )
  end

  defp latest_decision(application_id) do
    Repo.one(
      from(e in VerificationEvent,
        where:
          e.application_id == ^application_id and
            e.event in [:approved, :rejected, :changes_requested, :revoked],
        order_by: [desc: e.seq],
        limit: 1,
        select: %{decision: e.event, reason_code: e.reason_code, decided_at: e.occurred_at}
      ),
      @unlogged
    )
  end

  defp cast(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast(_id), do: :error

  @doc false
  @spec record_event!(VerificationApplication.t(), VerificationEvent.event(), map(), DateTime.t()) ::
          :ok
  def record_event!(application, event, attrs, now) do
    %VerificationEvent{} =
      Repo.insert!(
        struct!(
          VerificationEvent,
          Map.merge(
            %{
              gym_id: application.gym_id,
              application_id: application.id,
              event: event,
              application_revision: application.revision,
              occurred_at: now
            },
            attrs
          )
        ),
        @unlogged
      )

    :ok
  end

  @doc false
  @spec audit!(VerificationApplication.t(), atom(), Ecto.UUID.t() | nil, DateTime.t()) :: :ok
  def audit!(application, type, actor_user_id, now) do
    Audit.record!(
      %{
        gym_id: application.gym_id,
        actor_user_id: actor_user_id,
        event_type: type,
        verification_application_id: application.id
      },
      now
    )
  end

  defp now, do: usec(Clock.utc_now())

  defp usec(%DateTime{microsecond: {us, _}} = at), do: %{at | microsecond: {us, 6}}
end
