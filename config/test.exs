import Config

# Configure your database
#
# The test database is always separate from development. DATABASE_URL is
# deliberately ignored in test; use TEST_DATABASE_URL to point at another
# server (see config/runtime.exs).
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :simple_fit, SimpleFit.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "simple_fit_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :simple_fit, SimpleFitWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tHkFROi6SIgZOTA5TukSa/GlLa4jqiwVQPxW+b6BhHteZDroFqYQxgekjxeAEoMS",
  server: false

# Test-only session signing secret (the policy itself is the production one).
config :simple_fit, SimpleFit.Accounts.Sessions,
  secret_key_base: "tHkFROi6SIgZOTA5TukSa/GlLa4jqiwVQPxW+b6BhHteZDroFqYQxgekjxeAEoMS"

# Test-only email authentication key material (the policy is the production
# one, ADR 0012) and a reserved .example web app for E01 links.
config :simple_fit, SimpleFit.Accounts.EmailAuth,
  secret_key_base: "tHkFROi6SIgZOTA5TukSa/GlLa4jqiwVQPxW+b6BhHteZDroFqYQxgekjxeAEoMS",
  web_app_url: "https://app.simplefit.example"

# Jobs are never executed automatically in tests: assert on enqueued jobs
# (Oban.Testing) and run them explicitly with perform_job/2.
config :simple_fit, Oban, testing: :manual

# The local web client origin, so CORS behaviour is tested deterministically.
config :simple_fit, SimpleFitWeb.CORS, allowed_origins: ["http://localhost:3000"]
config :simple_fit, :attach_job_logger, false

# Sentry collects events in memory (Sentry.Test); nothing leaves the process.
# The DSN is a local placeholder, not an account.
config :sentry, dsn: "http://public:secret@localhost:9/1", test_mode: true
config :simple_fit, :sentry_rate_limiting, nil

# Spans are collected synchronously by tests (otel_simple_processor with a pid
# exporter set in the test); nothing is exported.
config :opentelemetry,
  traces_exporter: :none,
  processors: [
    {SimpleFit.Observability.SpanSanitizer, %{}},
    {:otel_simple_processor, %{name: :global}}
  ]

# Providers never reach the network in tests. Adapter tests stub HTTP with
# Req.Test; everything else uses these deterministic adapters.
config :simple_fit, SimpleFit.Storage,
  adapter: SimpleFit.Storage.Fake,
  bucket: "simplefit-test"

config :simple_fit, SimpleFit.Email,
  adapter: SimpleFit.EmailTestAdapter,
  # Test-only key for encrypted email job payloads (ADR 0011).
  payload_key_base: "tHkFROi6SIgZOTA5TukSa/GlLa4jqiwVQPxW+b6BhHteZDroFqYQxgekjxeAEoMS",
  from: "SimpleFit <no-reply@simplefit.test>"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
