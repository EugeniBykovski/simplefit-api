# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
#
# Secrets never belong in config files. Anything secret or deployment
# specific is read from the environment in config/runtime.exs.

# General application configuration
import Config

config :simple_fit,
  ecto_repos: [SimpleFit.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Primary keys are UUIDs so public identifiers never leak row counts or
# creation order. See docs/architecture/adr/0001-architecture-baseline.md.
config :simple_fit, SimpleFit.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime]

# Interactive API docs (/api/docs) and the served OpenAPI document
# (/api/openapi). Enabled in dev and test; production opts in explicitly
# through API_DOCS_ENABLED (see config/runtime.exs).
config :simple_fit, :api_docs, enabled: true

# Cross-origin allow-list (SimpleFitWeb.CORS). Empty = no browser origin is
# allowed (fail closed). Set per environment in config/runtime.exs from
# CORS_ALLOWED_ORIGINS; see docs/architecture/adr/0007-cors-policy.md.
config :simple_fit, SimpleFitWeb.CORS, allowed_origins: []

# Background jobs (Oban, PostgreSQL-backed). See docs/architecture/adr/0006.
# Queues stay minimal: add one only when a workload needs its own
# concurrency limit. Completed/cancelled/discarded jobs are pruned after a day,
# which also bounds how long job arguments (e.g. email contents) are kept.
config :simple_fit, Oban,
  engine: Oban.Engines.Basic,
  repo: SimpleFit.Repo,
  queues: [default: 10, mailers: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# Privacy-safe job outcome logs (SimpleFit.Observability.JobLogger), instead
# of Oban's default logger, which writes job args.
config :simple_fit, :attach_job_logger, true

# Configure the endpoint
config :simple_fit, SimpleFitWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SimpleFitWeb.ErrorJSON],
    layout: false
  ]

# Logger metadata allow-list (see docs/architecture/adr/0008-observability.md).
# `request_id` correlates with the `request_id` in API error responses;
# `otel_trace_id`/`otel_span_id` with traces. Service, environment and release
# are global metadata set by SimpleFit.Observability.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :otel_trace_id,
    :otel_span_id,
    :method,
    :route,
    :status,
    :duration_ms,
    :provider,
    :reason,
    :missing,
    :worker,
    :queue,
    :job_id,
    :attempt,
    :max_attempts,
    :state,
    :error_kind,
    :error_type
  ]

# One structured "request completed" event per request comes from
# SimpleFit.Observability.RequestLogger; Phoenix's text request logs are off.
config :phoenix, :logger, false

# Error tracking (Sentry). Disabled without SENTRY_DSN (config/runtime.exs).
# Never send PII, request data or source context; SimpleFit.Observability.
# SentryFilter strips every event.
config :sentry,
  dsn: nil,
  send_default_pii: false,
  enable_source_code_context: false,
  in_app_otp_apps: [:simple_fit],
  integrations: [oban: [capture_errors: true]]

# Tracing (OpenTelemetry). No exporter unless OTEL_EXPORTER_OTLP_ENDPOINT is
# set. The processor chain (SpanSanitizer first) is set per environment in
# config/runtime.exs and config/test.exs: Config would merge, not replace,
# a processors list declared here.
config :opentelemetry,
  resource: [service: [name: "simplefit-api"]],
  traces_exporter: :none

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Parameters whose key contains any of these strings are replaced with
# "[FILTERED]" in Phoenix request logs.
config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "token",
  "api_key",
  "private_key",
  "authorization",
  "credential"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
