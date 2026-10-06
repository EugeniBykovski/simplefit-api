import Config

# Local database defaults. Set DATABASE_URL to override them
# (see config/runtime.exs and .env.example).
config :simple_fit, SimpleFit.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "simple_fit_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# For development, we disable any cache and enable
# debugging and code reloading.
config :simple_fit, SimpleFitWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  # Errors are rendered with the API error envelope in dev too, so web and
  # mobile developers code against the real contract. Exceptions and stack
  # traces still appear in the server log. Flip to `true` temporarily to get
  # Plug.Debugger pages while debugging a crash.
  debug_errors: false,
  # Development-only value. Production reads SECRET_KEY_BASE at runtime.
  secret_key_base: "8YBMJlfoU9bSnKqnNYznwMHi94VUVsNfWHLLiIFiB7Fhy1hpnhfVR+5rXnu+5LHW",
  watchers: []

# Development-only session signing secret and a non-Secure refresh cookie,
# because the API is served over plain http://localhost:4000 here.
config :simple_fit, SimpleFit.Accounts.Sessions,
  secret_key_base: "8YBMJlfoU9bSnKqnNYznwMHi94VUVsNfWHLLiIFiB7Fhy1hpnhfVR+5rXnu+5LHW"

config :simple_fit, SimpleFitWeb.SessionTransport, secure_cookie: false

# Development-only email authentication key material (ADR 0012); E01 links
# point at the local web app unless WEB_APP_URL is exported.
config :simple_fit, SimpleFit.Accounts.EmailAuth,
  secret_key_base: "8YBMJlfoU9bSnKqnNYznwMHi94VUVsNfWHLLiIFiB7Fhy1hpnhfVR+5rXnu+5LHW",
  web_app_url: "http://localhost:3000"

# Transactional email (ADR 0011): development-only payload key, http CTA
# URLs for the local web app, and the template preview at /dev/emails.
config :simple_fit, SimpleFit.Email,
  payload_key_base: "8YBMJlfoU9bSnKqnNYznwMHi94VUVsNfWHLLiIFiB7Fhy1hpnhfVR+5rXnu+5LHW"

config :simple_fit, SimpleFit.Email.Templates, allow_http_urls: true
config :simple_fit, :email_previews, enabled: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message $metadata\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
