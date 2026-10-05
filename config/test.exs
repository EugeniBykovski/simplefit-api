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

# Jobs are never executed automatically in tests: assert on enqueued jobs
# (Oban.Testing) and run them explicitly with perform_job/2.
config :simple_fit, Oban, testing: :manual
config :simple_fit, :attach_oban_logger, false

# Providers never reach the network in tests. Adapter tests stub HTTP with
# Req.Test; everything else uses these deterministic adapters.
config :simple_fit, SimpleFit.Storage,
  adapter: SimpleFit.Storage.Fake,
  bucket: "simplefit-test"

config :simple_fit, SimpleFit.Email,
  adapter: SimpleFit.EmailTestAdapter,
  from: "SimpleFit <no-reply@simplefit.test>"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
