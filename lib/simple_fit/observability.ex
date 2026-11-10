defmodule SimpleFit.Observability do
  @moduledoc """
  Operational observability: what the system did, never what users sent.
  See docs/architecture/adr/0008-observability.md.

  Three separate concerns, each with the ecosystem-standard tool:

    * **Logs** (`Logger`, JSON in production): structured events with
      `request_id`, `trace_id`/`span_id`, service, environment and release.
      `SimpleFit.Observability.LogRedactor` redacts the text of every event,
      crash reports included (SF-29).
      `SimpleFit.Observability.RequestLogger` writes one line per request,
      `SimpleFit.Observability.JobLogger` one per job outcome.
    * **Error tracking** (Sentry): unexpected, actionable failures only.
      `SimpleFit.Observability.SentryFilter` decides what is sent and strips it.
    * **Tracing** (OpenTelemetry): Phoenix/Bandit, Ecto, Oban and Req spans
      from the maintained instrumentation libraries, plus provider boundary
      spans. `SimpleFit.Observability.SpanSanitizer` removes sensitive
      attributes from every span. Exported only when an OTLP endpoint is set.

  Nothing here is on the critical path: every backend is optional, export
  is asynchronous and batched, and telemetry handlers never raise into a
  request or job.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Observability.{
    JobLogger,
    LogRedactor,
    ProviderTracing,
    RequestLogger,
    SentryFilter
  }

  alias SimpleFit.Repo

  @service "simplefit-api"

  @typedoc "Service metadata shared by logs, Sentry and OpenTelemetry."
  @type metadata :: %{service: String.t(), environment: String.t(), release: String.t()}

  @doc """
  Service name, deployment environment and release, from
  `config :simple_fit, :observability` (set in config/runtime.exs from
  `SENTRY_ENVIRONMENT` / `SENTRY_RELEASE`, with safe local defaults).
  """
  @spec metadata() :: metadata()
  def metadata do
    config = Application.get_env(:simple_fit, :observability, [])

    %{
      service: @service,
      environment: Keyword.get(config, :environment, "dev"),
      release: Keyword.get(config, :release, default_release())
    }
  end

  @doc "`simplefit-api@<version from mix.exs>`: the release when none is provided."
  @spec default_release() :: String.t()
  def default_release, do: "#{@service}@#{Application.spec(:simple_fit, :vsn)}"

  @doc """
  Attaches the observability handlers. Called once from
  `SimpleFit.Application.start/2`, before the supervision tree starts.
  """
  @spec setup() :: :ok
  def setup do
    put_global_log_metadata()
    # Before anything else logs: every event's text is redacted (SF-29).
    LogRedactor.attach()
    RequestLogger.attach()

    if Application.get_env(:simple_fit, :attach_job_logger, false) do
      JobLogger.attach()
    end

    setup_tracing()
    SentryFilter.attach_logger_handler()
    :ok
  end

  # Every log event carries the service identity (logger primary metadata).
  defp put_global_log_metadata do
    %{service: service, environment: environment, release: release} = metadata()

    :ok =
      :logger.update_primary_config(%{
        metadata: %{service: service, environment: environment, release: release}
      })
  end

  defp setup_tracing do
    # Incoming trace context from the public internet is linked, not trusted
    # as a parent: clients must not control trace ids or sampling.
    _ = OpentelemetryBandit.setup(public_endpoint: true)
    _ = OpentelemetryPhoenix.setup(adapter: :bandit)
    # Statement capture stays off: timing and table, never SQL or parameters.
    _ = OpentelemetryEcto.setup([:simple_fit, :repo], db_statement: :disabled)
    # Job spans (worker, queue, attempt; never args). Plugin spans (pruner,
    # lifeline) are housekeeping noise.
    _ = OpentelemetryOban.setup(plugin: :disabled)
    ProviderTracing.attach()
  end

  @doc """
  Background job counts for the operator health card (SF-121), from Oban's own
  table: jobs waiting to run (available, scheduled or retrying) and jobs discarded
  (retries exhausted) since `since`. Counts only: no worker arguments, errors or
  payloads leave the database. Discarded jobs are pruned after a day, so `since`
  must be within the last day.
  """
  @spec job_counts(DateTime.t()) :: %{waiting: non_neg_integer(), discarded: non_neg_integer()}
  def job_counts(%DateTime{} = since) do
    Repo.one(
      from(j in Oban.Job,
        select: %{
          waiting: filter(count(), j.state in ["available", "scheduled", "retryable"]),
          discarded: filter(count(), j.state == "discarded" and j.discarded_at >= ^since)
        }
      )
    )
  end
end
