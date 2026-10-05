defmodule SimpleFit.Observability.JobLogger do
  @moduledoc """
  One structured log event per Oban job outcome. Replaces
  `Oban.Telemetry.attach_default_logger/1`, which writes the job's `args`
  into every line: email jobs carry the recipient, subject and body, and
  future jobs will carry other personal data.

  Logged: `worker`, `queue`, `job_id`, `attempt`, `max_attempts`, `state`,
  `duration_ms` and, on failure, the error kind and type (an exception
  module or a `SimpleFit.Provider` reason). Never `args`, `meta`, `tags` or
  error messages.

  Failures log at `:warning`: retries are expected. Jobs that exhaust their
  attempts are reported to Sentry by its Oban integration
  (`SimpleFit.Observability.SentryFilter.report_job_error?/2`), not here, so
  one failure is never reported twice.
  """

  require Logger

  @handler_id {__MODULE__, :job}

  @doc "Attaches the telemetry handlers (idempotent)."
  @spec attach() :: :ok
  def attach do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        [[:oban, :job, :stop], [:oban, :job, :exception]],
        &__MODULE__.handle_event/4,
        nil
      )
  end

  @doc false
  def handle_event([:oban, :job, :stop], measurements, %{job: job} = metadata, _config) do
    Logger.info("job completed", job_metadata(job, metadata, measurements))
  end

  def handle_event([:oban, :job, :exception], measurements, %{job: job} = metadata, _config) do
    error = [error_kind: metadata[:kind], error_type: error_type(metadata[:reason])]
    Logger.warning("job failed", job_metadata(job, metadata, measurements) ++ error)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp job_metadata(job, metadata, measurements) do
    [
      worker: job.worker,
      queue: job.queue,
      job_id: job.id,
      attempt: job.attempt,
      max_attempts: job.max_attempts,
      state: metadata[:state],
      duration_ms:
        System.convert_time_unit(measurements[:duration] || 0, :native, :microsecond) / 1000
    ]
  end

  # The type only: a module name or a normalized provider reason atom.
  defp error_type(%Oban.PerformError{reason: {:error, reason}}) when is_atom(reason), do: reason
  defp error_type(%Oban.PerformError{}), do: Oban.PerformError
  defp error_type(%{__exception__: true, __struct__: module}), do: module
  defp error_type(reason) when is_atom(reason), do: reason
  defp error_type(_reason), do: :unknown
end
