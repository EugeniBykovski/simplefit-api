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
  metadata: [:request_id]

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
