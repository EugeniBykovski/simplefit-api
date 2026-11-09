defmodule SimpleFit.Sponsors.EvidenceCleanupWorker do
  @moduledoc """
  Storage cleanup of sponsor application evidence (SF-114; `Oban.Plugins.Cron`,
  every 30 minutes), as `SimpleFit.Gyms.VerificationCleanupWorker`:

    * an upload never confirmed within a day of its presigned URL's expiry is
      marked `removed` (`abandoned`);
    * the storage object of every removed, **never-submitted** document is deleted
      once, and the deletion recorded (`object_deleted_at`).

  This is technical cleanup of documents nobody submitted, not a retention
  policy. **Submitted evidence is never deleted here** (the database refuses it):
  its retention and deletion need an approved policy (D-SA18, counsel). A storage
  failure leaves the row for the next run; the database and storage can't diverge
  into a lost submitted object. At most 100 objects per run.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 600]

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.{Clock, Repo, Storage}
  alias SimpleFit.Sponsors.ApplicationEvidence

  @unlogged [log: false]
  @abandoned_after 24 * 3600
  @batch 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _counts = sweep(now())
    :ok
  end

  @doc false
  @spec sweep(DateTime.t()) :: %{abandoned: non_neg_integer(), deleted: non_neg_integer()}
  def sweep(now) do
    cutoff = DateTime.add(now, -@abandoned_after)

    {abandoned, _} =
      Repo.update_all(
        from(e in ApplicationEvidence,
          where: e.status == :pending_upload and e.upload_expires_at < ^cutoff
        ),
        [set: [status: :removed, removed_at: now, removed_reason: "abandoned", updated_at: now]],
        @unlogged
      )

    deleted =
      Repo.all(
        from(e in ApplicationEvidence,
          where: e.status == :removed and is_nil(e.submission_id) and is_nil(e.object_deleted_at),
          order_by: [asc: e.removed_at, asc: e.id],
          limit: @batch,
          select: %{id: e.id, object_key: e.object_key}
        ),
        @unlogged
      )
      |> Enum.count(&delete_object(&1, now))

    %{abandoned: abandoned, deleted: deleted}
  end

  defp delete_object(%{id: id, object_key: key}, now) do
    case Storage.delete(key) do
      :ok ->
        Repo.update_all(
          from(e in ApplicationEvidence, where: e.id == ^id and is_nil(e.object_deleted_at)),
          [set: [object_deleted_at: now, updated_at: now]],
          @unlogged
        )

        true

      {:error, _reason} ->
        false
    end
  end

  defp now do
    %DateTime{microsecond: {us, _}} = at = Clock.utc_now()
    %{at | microsecond: {us, 6}}
  end
end
