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

# Oban's structured job logger (start/stop/exception per job).
config :simple_fit, :attach_oban_logger, true

# Configure the endpoint
config :simple_fit, SimpleFitWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SimpleFitWeb.ErrorJSON],
    layout: false
  ]

# Configure Elixir's Logger. `request_id` is attached to every log line
# emitted while serving a request so logs can be correlated with the
# `request_id` returned in API error responses.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :provider, :status, :reason, :missing]

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
