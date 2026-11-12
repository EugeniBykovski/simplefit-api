defmodule SimpleFit.Sponsors.Evidence do
  @moduledoc """
  Evidence of the viewer's own sponsor application (SF-114, ADR 0032), on the
  SF-103 pattern. Part of `SimpleFit.Sponsors`; every operation names only the
  viewer's current application (found by their user id) and an evidence id of it.

  1. **Initiate** (`initiate/3`): the client announces `kind`, `file_name`,
     `content_type` and `byte_size` at the application's `expected_revision`. The
     server checks the policy (PDF, JPEG or PNG; at most 10 MiB; at most five live
     documents), builds the key itself
     (`sponsors/applications/<application>/evidence/<evidence>`), records a
     `pending_upload` row and returns a presigned `PUT` valid for 15 minutes that
     storage accepts only with exactly that type and size. The key never leaves
     the server; no client key, bucket or URL is ever accepted.
  2. **Confirm** (`confirm/3`): the server reads the object's size and type with a
     server-signed `HEAD` (`SimpleFit.Storage.stat/2`, outside any lock), then, in
     a transaction under the application's lock, attaches it only if both match
     what it allowed and the upload hasn't expired. Confirming again answers the
     same; a missing, different or late object attaches nothing. A HEAD is not a
     malware scan: documents are always reported `scanned: false`.
  3. **Remove** (`remove/4`): a document not part of a submission can be removed
     (also to replace it). Submitted documents are frozen by the database.

  Rows are never deleted. Objects of removed, never-submitted documents are
  deleted by `SimpleFit.Sponsors.EvidenceCleanupWorker`, which also abandons
  uploads never confirmed. **Submitted evidence is never deleted**: its retention
  needs an approved policy (D-SA18, counsel). Uploads exist only where
  `config :simple_fit, SimpleFit.Sponsors, evidence_uploads: true` (off in
  production until a file scanner or an accepted risk is approved, D-SA09).
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{RateLimit, Repo, Storage}
  alias SimpleFit.Sponsors.{Application, ApplicationEvidence, Applications}
  alias SimpleFit.Storage.ObjectKey

  @unlogged [log: false]
  @content_types ["application/pdf", "image/jpeg", "image/png"]
  @max_bytes 10 * 1024 * 1024
  @max_live 5
  @upload_expires_in 900
  # A client that finished its PUT just before the URL expired may confirm a little later.
  @confirm_grace 3600
  @kinds ~w(logo brand_deck campaign_brief other)

  @doc "The upload policy (for clients)."
  @spec policy() :: map()
  def policy,
    do: %{
      available: enabled?(),
      content_types: @content_types,
      max_bytes: @max_bytes,
      max_documents: @max_live,
      kinds: @kinds,
      scanned: false
    }

  @doc """
  Whether evidence uploads exist in this environment: enabled by the deployment
  (`SPONSOR_EVIDENCE_UPLOADS`) and not suspended by an operator (SF-128).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: SimpleFit.Configuration.enabled?("sponsor.evidence_uploads")

  @doc "The application's live (not removed) documents, oldest first."
  @spec live(Ecto.UUID.t()) :: [ApplicationEvidence.t()]
  def live(application_id),
    do:
      Repo.all(
        from(e in ApplicationEvidence,
          where: e.application_id == ^application_id and e.status != :removed,
          order_by: [e.inserted_at, e.id]
        ),
        @unlogged
      )

  @doc "Announces a document; returns the view, the document and the presigned upload."
  @spec initiate(User.t(), map(), map()) ::
          {:ok, {map(), ApplicationEvidence.t(), Storage.Presigned.t()}} | {:error, term()}
  def initiate(%User{} = user, params, ctx \\ %{}) do
    with :ok <- available(),
         {:ok, request} <- cast_initiate(params),
         :ok <- limit("sponsor_evidence_initiate", user.id, 30, 3600) do
      Repo.transaction(fn -> initiate!(user, request, ctx) end)
    end
  end

  defp initiate!(user, request, ctx) do
    application = editable!(user, request.expected_revision)

    if length(live(application.id)) >= @max_live,
      do: Repo.rollback({:conflict, %{evidence: "limit_reached"}})

    id = Ecto.UUID.generate()

    with {:ok, key} <-
           ObjectKey.build(["sponsors", "applications", application.id, "evidence", id]),
         {:ok, upload} <-
           Storage.presign_upload(key,
             content_type: request.content_type,
             content_length: request.byte_size,
             expires_in: @upload_expires_in
           ) do
      evidence =
        Repo.insert!(
          %ApplicationEvidence{
            id: id,
            application_id: application.id,
            kind: String.to_existing_atom(request.kind),
            status: :pending_upload,
            object_key: key,
            content_type: request.content_type,
            byte_size: request.byte_size,
            file_name: request.file_name,
            created_by_user_id: user.id,
            upload_expires_at: upload.expires_at |> DateTime.truncate(:second) |> to_usec()
          },
          @unlogged
        )

      application =
        Applications.touch!(application, user, ctx, "sponsor_application.evidence_added")

      {Applications.view(application), evidence, upload}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Attaches an uploaded document after verifying it in storage (idempotent)."
  @spec confirm(User.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def confirm(%User{} = user, evidence_id, ctx \\ %{}) do
    # The HEAD runs before the transaction: no lock is held during the storage call.
    with :ok <- available(),
         {:ok, evidence} <- own(user, evidence_id),
         {:ok, seen} <- observe(evidence) do
      Repo.transaction(fn -> confirm!(user, evidence.id, seen, ctx) end)
    end
  end

  defp confirm!(user, evidence_id, seen, ctx) do
    application = Applications.lock_current(user.id) || Repo.rollback(:not_found)
    evidence = lock(application.id, evidence_id) || Repo.rollback(:not_found)

    case {evidence.status, seen} do
      {:uploaded, _} ->
        Applications.view(application)

      {:removed, _} ->
        Repo.rollback({:conflict, %{evidence: "removed"}})

      {:pending_upload, nil} ->
        Repo.rollback({:conflict, %{upload: "not_found"}})

      {:pending_upload, seen} ->
        with {:error, details} <- attachable(application, evidence, seen),
             do: Repo.rollback({:conflict, details})

        Repo.update!(change(evidence, status: :uploaded, uploaded_at: now()), @unlogged)

        Applications.view(
          Applications.touch!(application, user, ctx, "sponsor_application.evidence_uploaded")
        )
    end
  end

  # What storage reported must be exactly what was allowed, in time.
  defp attachable(application, evidence, seen) do
    cond do
      application.status not in Application.editable_statuses() ->
        {:error, %{application: "not_editable"}}

      expired?(evidence) ->
        {:error, %{upload: "expired"}}

      seen.content_length != evidence.byte_size or
          media_type(seen.content_type) != evidence.content_type ->
        {:error, %{upload: "mismatch"}}

      true ->
        :ok
    end
  end

  @doc "Removes a document that isn't part of a submission (idempotent)."
  @spec remove(User.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def remove(%User{} = user, evidence_id, params, ctx \\ %{}) do
    with :ok <- available(),
         {:ok, expected} <- cast_revision(params),
         {:ok, id} <- uuid(evidence_id) do
      Repo.transaction(fn -> remove!(user, id, expected, ctx) end)
    end
  end

  defp remove!(user, id, expected, ctx) do
    application = editable!(user, expected)
    evidence = lock(application.id, id) || Repo.rollback(:not_found)

    cond do
      evidence.status == :removed ->
        Applications.view(application)

      evidence.submission_id ->
        Repo.rollback({:conflict, %{evidence: "submitted"}})

      true ->
        Repo.update!(
          change(evidence, status: :removed, removed_at: now(), removed_reason: "owner"),
          @unlogged
        )

        Applications.view(
          Applications.touch!(application, user, ctx, "sponsor_application.evidence_removed")
        )
    end
  end

  @doc false
  # At submission, inside its transaction: the uploaded documents, locked.
  @spec lock_uploaded!(Ecto.UUID.t()) :: [ApplicationEvidence.t()]
  def lock_uploaded!(application_id),
    do:
      Repo.all(
        from(e in ApplicationEvidence,
          where: e.application_id == ^application_id and e.status == :uploaded,
          order_by: [e.inserted_at, e.id],
          lock: "FOR UPDATE"
        ),
        @unlogged
      )

  @doc false
  # What a submission snapshot says about its documents: no key, no file name.
  @spec describe([ApplicationEvidence.t()]) :: [map()]
  def describe(evidence),
    do:
      Enum.map(
        evidence,
        &%{
          "evidence_id" => &1.id,
          "kind" => Atom.to_string(&1.kind),
          "content_type" => &1.content_type,
          "byte_size" => &1.byte_size,
          "scanned" => false
        }
      )

  @doc false
  # Freezes the documents into `submission_id` (a resubmission keeps earlier ones).
  @spec attach!([ApplicationEvidence.t()], Ecto.UUID.t()) :: :ok
  def attach!(evidence, submission_id) do
    for e <- evidence, is_nil(e.submission_id) do
      Repo.update!(change(e, submission_id: submission_id), @unlogged)
    end

    :ok
  end

  ## Helpers

  defp available, do: if(enabled?(), do: :ok, else: {:error, :service_unavailable})

  defp editable!(user, expected) do
    application = Applications.lock_current(user.id) || Repo.rollback(:not_found)

    cond do
      application.status not in Application.editable_statuses() ->
        Repo.rollback(
          {:conflict, %{application: "not_editable", status: Atom.to_string(application.status)}}
        )

      application.revision != expected ->
        Repo.rollback({:revision_conflict, %{current_revision: application.revision}})

      true ->
        application
    end
  end

  defp own(user, evidence_id) do
    with {:ok, id} <- uuid(evidence_id),
         %ApplicationEvidence{} = evidence <-
           Repo.one(
             from(e in ApplicationEvidence,
               join: a in Application,
               on: a.id == e.application_id,
               where: e.id == ^id and a.applicant_user_id == ^user.id
             ),
             @unlogged
           ) do
      {:ok, evidence}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock(application_id, id),
    do:
      Repo.one(
        from(e in ApplicationEvidence,
          where: e.id == ^id and e.application_id == ^application_id,
          lock: "FOR UPDATE"
        ),
        @unlogged
      )

  defp observe(%ApplicationEvidence{status: :pending_upload} = evidence) do
    case Storage.stat(evidence.object_key) do
      {:ok, seen} ->
        {:ok, seen}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, reason} when reason in [:timeout, :unavailable, :rate_limited] ->
        {:error, :service_unavailable}

      {:error, _other} ->
        {:error, :service_unavailable}
    end
  end

  # Attached or removed: the transaction answers without a storage call.
  defp observe(_evidence), do: {:ok, nil}

  defp expired?(evidence),
    do: DateTime.compare(now(), DateTime.add(evidence.upload_expires_at, @confirm_grace)) == :gt

  # `image/png; charset=...` -> `image/png`
  defp media_type(nil), do: nil

  defp media_type(type),
    do: type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

  defp cast_initiate(params) do
    types = %{
      expected_revision: :integer,
      kind: :string,
      file_name: :string,
      content_type: :string,
      byte_size: :integer
    }

    {%{}, types}
    |> cast(params, Map.keys(types))
    |> validate_required(Map.keys(types))
    |> validate_number(:expected_revision, greater_than_or_equal_to: 1)
    |> validate_inclusion(:kind, @kinds)
    |> update_change(:file_name, &String.trim/1)
    |> validate_length(:file_name, min: 1, max: 120)
    |> validate_format(:file_name, ~r/\A[^\x00-\x1F\/\\]+\z/u)
    |> validate_inclusion(:content_type, @content_types)
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: @max_bytes)
    |> reject_unknown(params, Enum.map(Map.keys(types), &Atom.to_string/1))
    |> apply_action(:validate)
  end

  defp cast_revision(params) do
    {%{}, %{expected_revision: :integer}}
    |> cast(params, [:expected_revision])
    |> validate_required([:expected_revision])
    |> validate_number(:expected_revision, greater_than_or_equal_to: 1)
    |> reject_unknown(params, ["expected_revision"])
    |> apply_action(:validate)
    |> case do
      {:ok, %{expected_revision: revision}} -> {:ok, revision}
      error -> error
    end
  end

  defp reject_unknown(changeset, params, known) do
    params
    |> Map.keys()
    |> Enum.reject(&(&1 in known))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a field of the request", []}} | acc.errors], valid?: false}
    end)
  end

  defp limit(bucket, user_id, count, period) do
    RateLimit.hit([{bucket, :crypto.hash(:sha256, user_id), count, period}])
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp to_usec(%DateTime{} = dt), do: %{dt | microsecond: {0, 6}}
  defp now, do: DateTime.utc_now()
end
