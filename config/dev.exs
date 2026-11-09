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
  # Loopback only: other machines cannot connect. For physical-device testing
  # export PHX_BIND_ALL=true, which config/runtime.exs turns into 0.0.0.0.
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

# Development-only coach invitation key material (SF-57); E08 links point at
# the local web app unless WEB_APP_URL is exported.
config :simple_fit, SimpleFit.Coaching.Invitations,
  secret_key_base: "8YBMJlfoU9bSnKqnNYznwMHi94VUVsNfWHLLiIFiB7Fhy1hpnhfVR+5rXnu+5LHW",
  web_app_url: "http://localhost:3000"

# Development-only gym rate-limit key material (SF-83).
config :simple_fit, SimpleFit.Gyms,
  secret_key_base: "8YBMJlfoU9bSnKqnNYznwMHi94VUVsNfWHLLiIFiB7Fhy1hpnhfVR+5rXnu+5LHW",
  web_app_url: "http://localhost:3000",
  # SF-95: member invitations (E07) are sent locally (Log adapter); in
  # production they stay off until the recipient flow exists.
  member_invitations: true,
  # SF-133: staff invitations (E06) likewise: production keeps them off until
  # the deployed /invite/staff page passed its smoke test.
  staff_invitations: true

# Transactional email (ADR 0011): development-only payload key, http CTA
# URLs for the local web app, and the template preview at /dev/emails.
config :simple_fit, SimpleFit.Email,
  payload_key_base: "8YBMJlfoU9bSnKqnNYznwMHi94VUVsNfWHLLiIFiB7Fhy1hpnhfVR+5rXnu+5LHW"

config :simple_fit, SimpleFit.Email.Templates, allow_http_urls: true
config :simple_fit, :email_previews, enabled: true

# LOCAL DEVELOPMENT coaching mode (SF-81, ADR 0025): the Coach–Fighter
# workflow without legal documents. Allowed in this build only; it turns on
# solely when SIMPLEFIT_LOCAL_DEV_COACHING=enabled is exported AND the
# endpoint is loopback-only AND the live database is local and one of these.
config :simple_fit, SimpleFit.Coaching.LocalDevelopment,
  allowed: true,
  databases: ["simple_fit_dev"]

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message $metadata\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# SF-30: `mix e2e.email_code` for local end-to-end runs. Never in prod.
config :simple_fit, :e2e_tools, enabled: true

# SF-136: review on a local machine goes through the fixture authority, which is not
# compiled into a production build and is recorded as `local_fixture`.
# SF-110: operator security keys against the local web client, and the local
# development ceremony key written by `mix operators.dev_ceremony` (outside Git, in
# .operator-dev/). Ceremonies it signs are recorded as local_development_ceremony.
# SF-111: signs operator audit log cursors (development only value).
config :simple_fit, SimpleFit.Operators,
  secret_key_base: "dev-operators-7Qm2Xc9LpV4sKd8NwR1tYh6JbF3gZe5AuTi0OyPnMkWqHxCvBlSjDrEaGfUo"

config :simple_fit, SimpleFit.Operators.WebAuthn,
  rp_id: "localhost",
  origin: "http://localhost:3000",
  rp_name: "SimpleFit Control Plane (development)"

config :simple_fit, SimpleFit.Operators.Bootstrap,
  environment: "development",
  trusted_keys:
    (case File.read(Path.expand("../.operator-dev/public.key", __DIR__)) do
       {:ok, key} -> %{"local-development" => {String.trim(key), :local_development_ceremony}}
       {:error, _} -> %{}
     end)

# SF-113: a local end-to-end run may point the legal registry at the test-fixture
# registry (test-only, unapproved texts, e.g. the sponsor declaration fixture) with
# SIMPLEFIT_DEV_LEGAL_REGISTRY. Unset, development uses priv/legal like production.
if path = System.get_env("SIMPLEFIT_DEV_LEGAL_REGISTRY") do
  config :simple_fit, SimpleFit.Legal, registry_path: path, allow_test_fixtures: true
end

# SF-112: sponsor organizations are provisioned locally by the fixture authority,
# which a production build refuses (ADR 0030). Recorded as `local_fixture`.
config :simple_fit, SimpleFit.Sponsors.Provisioning, local_fixture: true

# SF-114: sponsor application evidence uploads and emails exist here; production keeps
# both off until approved (D-SA09 file scanning; email copy and design).
config :simple_fit, SimpleFit.Sponsors,
  secret_key_base: "dev-sponsors-4Hq7Wz1Kc9Lm3Np8Rt2Vx6Yb0Fd5Gj7Ks1Mw4Pz9Qc3Rv8Tx2Ub6Ye0Ah5Jn",
  evidence_uploads: true,
  application_emails: true

config :simple_fit, SimpleFit.Gyms.VerificationAuthority,
  backend: SimpleFit.Gyms.VerificationAuthority.Local

config :simple_fit, SimpleFit.Gyms.VerificationAuthority.Local,
  ambient_secret: "local-fixture-reviewer",
  operators: [
    %{
      secret: "local-fixture-reviewer",
      actor_id: "33333333-3333-4333-8333-333333333333",
      user_id: "44444444-4444-4444-8444-444444444444",
      permissions: [
        :read_queue,
        :read_application,
        :read_evidence,
        :approve,
        :request_changes,
        :reject,
        :revoke
      ]
    }
  ]
