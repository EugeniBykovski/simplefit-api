import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is the single place where environment variables
# are read. Do not define compile-time configuration here.
#
# Every variable read here is documented in .env.example. The app does not
# load .env files itself; export variables in your shell (see README.md).

parse_boolean = fn name, default ->
  case System.get_env(name) do
    nil -> default
    value when value in ~w(true 1) -> true
    value when value in ~w(false 0) -> false
    value -> raise "environment variable #{name} must be true/false/1/0, got: #{inspect(value)}"
  end
end

# Optional variable: unset and empty both mean "not configured".
get_env = fn name ->
  case System.get_env(name) do
    nil -> nil
    value -> if String.trim(value) == "", do: nil, else: value
  end
end

# Validates a variable only when it is set: a present-but-malformed value is
# a deployment mistake and fails boot. Absent values are handled by the
# adapters, which fail closed at call time (see docs/architecture/adr/0005).
validate_env = fn name, pattern, hint ->
  case get_env.(name) do
    nil ->
      nil

    value ->
      if Regex.match?(pattern, value), do: value, else: raise("#{name} is invalid: #{hint}")
  end
end

storage_env = fn ->
  [
    bucket:
      validate_env.(
        "AWS_S3_BUCKET",
        ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/,
        "expected an S3 bucket name"
      ),
    region:
      validate_env.(
        "AWS_REGION",
        ~r/\A[a-z]{2}(-[a-z]+)+-\d\z/,
        "expected an AWS region such as eu-central-1"
      ),
    access_key_id: get_env.("AWS_ACCESS_KEY_ID"),
    secret_access_key: get_env.("AWS_SECRET_ACCESS_KEY"),
    session_token: get_env.("AWS_SESSION_TOKEN"),
    endpoint:
      validate_env.(
        "AWS_S3_ENDPOINT",
        ~r{\Ahttps?://[^/\s]+/?\z},
        "expected a base URL such as http://localhost:9000"
      ),
    key_prefix:
      validate_env.(
        "AWS_S3_KEY_PREFIX",
        ~r{\A([A-Za-z0-9][A-Za-z0-9._-]*/)+\z},
        "expected segments ending with a slash, e.g. staging/"
      )
  ]
end

email_env = fn ->
  [
    api_key: get_env.("RESEND_API_KEY"),
    # "addr@domain.tld" or "Name <addr@domain.tld>", without line breaks.
    from:
      validate_env.(
        "EMAIL_FROM",
        ~r/\A(?:[^<>\r\n]*<[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+>|[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+)\z/,
        "expected an address such as SimpleFit <no-reply@example.com>"
      )
  ]
end

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/simple_fit start
if System.get_env("PHX_SERVER") do
  config :simple_fit, SimpleFitWeb.Endpoint, server: true
end

config :simple_fit, SimpleFitWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Observability (docs/architecture/adr/0008-observability.md). One service
# identity for logs, Sentry and OpenTelemetry:
#   SENTRY_ENVIRONMENT  deployment environment (default: the Mix env)
#   SENTRY_RELEASE      release identifier, e.g. the git SHA
#                       (default: simplefit-api@<mix.exs version>)
observability_environment = get_env.("SENTRY_ENVIRONMENT") || Atom.to_string(config_env())

observability_release =
  get_env.("SENTRY_RELEASE") ||
    "simplefit-api@#{Application.spec(:simple_fit, :vsn) || Mix.Project.config()[:version]}"

config :simple_fit, :observability,
  environment: observability_environment,
  release: observability_release

# Sentry: disabled unless SENTRY_DSN is set (test uses Sentry.Test).
if config_env() != :test do
  config :sentry, dsn: get_env.("SENTRY_DSN")
end

config :sentry,
  environment_name: observability_environment,
  release: observability_release,
  before_send: {SimpleFit.Observability.SentryFilter, :before_send},
  integrations: [
    oban: [
      capture_errors: true,
      should_report_error_callback: &SimpleFit.Observability.SentryFilter.report_job_error?/2
    ]
  ]

# OpenTelemetry: spans are always created (trace ids in logs) but exported
# only when an OTLP endpoint is configured with the standard variables
# (OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_HEADERS, OTEL_TRACES_SAMPLER,
# OTEL_RESOURCE_ATTRIBUTES, ...), which the SDK reads itself.
if config_env() != :test and get_env.("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :opentelemetry, traces_exporter: :otlp
  config :opentelemetry_exporter, otlp_protocol: :http_protobuf
end

if config_env() != :test do
  # SpanSanitizer strips sensitive attributes before the batch processor,
  # which exports asynchronously and drops spans if the backend is down.
  config :opentelemetry,
    processors: [
      {SimpleFit.Observability.SpanSanitizer, %{}},
      {:otel_batch_processor, %{}}
    ]
end

config :opentelemetry,
  resource: [
    service: [name: "simplefit-api", version: observability_release],
    deployment: [environment: [name: observability_environment]]
  ]

case config_env() do
  :dev ->
    # Loopback by default; PHX_BIND_ALL=true listens on every IPv4 interface
    # so a physical device on the LAN can reach the API (development only).
    config :simple_fit, SimpleFitWeb.Endpoint,
      http: [ip: SimpleFitWeb.Endpoint.parse_dev_bind_all!(System.get_env("PHX_BIND_ALL"))]

    if database_url = System.get_env("DATABASE_URL") do
      config :simple_fit, SimpleFit.Repo, url: database_url
    end

    # Development works without provider accounts: real adapters are used
    # only when their credentials are exported.
    storage = storage_env.()

    config :simple_fit, SimpleFit.Storage, [
      {:adapter, if(storage[:bucket], do: SimpleFit.Storage.S3, else: SimpleFit.Storage.Fake)}
      | storage
    ]

    email = email_env.()

    config :simple_fit, SimpleFit.Email, [
      {:adapter, if(email[:api_key], do: SimpleFit.Email.Resend, else: SimpleFit.Email.Log)}
      | Keyword.update!(email, :from, &(&1 || "SimpleFit Dev <dev@simplefit.invalid>"))
    ]

    # E01 verification links point at the local web app unless overridden.
    if web_app_url = System.get_env("WEB_APP_URL") do
      config :simple_fit, SimpleFit.Accounts.EmailAuth,
        web_app_url: SimpleFit.Accounts.EmailAuth.parse_web_app_url!(web_app_url)
    end

    config :simple_fit, SimpleFitWeb.ClientIP,
      trusted_proxy_hops: SimpleFitWeb.ClientIP.parse_hops!(System.get_env("TRUSTED_PROXY_HOPS"))

    # Google sign-in (ADR 0013): unset means Google sign-in answers 503.
    config :simple_fit, SimpleFit.Identity.Google,
      client_ids:
        SimpleFit.Identity.Google.parse_client_ids!(System.get_env("GOOGLE_OAUTH_CLIENT_IDS"))

    # Sign in with Apple (ADR 0014): unset means Apple sign-in answers 503.
    config :simple_fit, SimpleFit.Identity.Apple,
      client_ids:
        SimpleFit.Identity.Apple.parse_client_ids!(System.get_env("APPLE_SIGN_IN_CLIENT_IDS"))

    # The local web client (simplefit-platform `pnpm dev`) by default;
    # CORS_ALLOWED_ORIGINS replaces the list (e.g. to add 127.0.0.1:3000).
    config :simple_fit, SimpleFitWeb.CORS,
      allowed_origins:
        SimpleFitWeb.CORS.parse_origins!(
          System.get_env("CORS_ALLOWED_ORIGINS", "http://localhost:3000")
        )

  :test ->
    # Never fall back to DATABASE_URL here: tests must not touch the
    # development (or any shared) database. The URL must name a dedicated
    # test database, e.g. ecto://postgres:postgres@db:5432/simple_fit_test
    if test_database_url = System.get_env("TEST_DATABASE_URL") do
      config :simple_fit, SimpleFit.Repo, url: test_database_url
    end

  :prod ->
    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if parse_boolean.("ECTO_IPV6", false), do: [:inet6], else: []

    config :simple_fit, SimpleFit.Repo,
      url: database_url,
      # TLS with peer certificate and hostname verification against the
      # system CA store. Set DATABASE_SSL=false only for databases reachable
      # exclusively over a private network.
      ssl: parse_boolean.("DATABASE_SSL", true),
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
      socket_options: maybe_ipv6

    # The secret key base signs/encrypts tokens and other secrets.
    # Generate one with: mix phx.gen.secret
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    if byte_size(secret_key_base) < 64 do
      raise "environment variable SECRET_KEY_BASE must be at least 64 bytes (mix phx.gen.secret)"
    end

    # Signs session access tokens (ADR 0010).
    config :simple_fit, SimpleFit.Accounts.Sessions, secret_key_base: secret_key_base

    # Email authentication (ADR 0012): code verifiers, target digests and
    # rate-limit keys are derived from the same secret with dedicated salts.
    # E01 links point at the web app, which must be https.
    config :simple_fit, SimpleFit.Accounts.EmailAuth,
      secret_key_base: secret_key_base,
      web_app_url:
        SimpleFit.Accounts.EmailAuth.parse_web_app_url!(
          System.get_env("WEB_APP_URL") ||
            raise("""
            environment variable WEB_APP_URL is missing.
            Set it to the https origin of the SimpleFit web app, for example: https://app.simplefit.com
            """),
          require_https: true
        )

    # Client IP for auth rate limits (ADR 0012). Default 0: the direct peer
    # address; set it only to the number of trusted proxies in front of the
    # app after the deployment topology is verified.
    config :simple_fit, SimpleFitWeb.ClientIP,
      trusted_proxy_hops: SimpleFitWeb.ClientIP.parse_hops!(System.get_env("TRUSTED_PROXY_HOPS"))

    # Google sign-in audiences (ADR 0013): the web, iOS and Android OAuth
    # client ids. Unset does not block boot; Google sign-in then answers 503.
    # A malformed value fails the boot.
    config :simple_fit, SimpleFit.Identity.Google,
      client_ids:
        SimpleFit.Identity.Google.parse_client_ids!(System.get_env("GOOGLE_OAUTH_CLIENT_IDS"))

    # Sign in with Apple audiences (ADR 0014): the iOS bundle id and the web
    # Services ID. Unset does not block boot; Apple sign-in then answers 503.
    # A malformed value fails the boot.
    config :simple_fit, SimpleFit.Identity.Apple,
      client_ids:
        SimpleFit.Identity.Apple.parse_client_ids!(System.get_env("APPLE_SIGN_IN_CLIENT_IDS"))

    host =
      System.get_env("PHX_HOST") ||
        raise """
        environment variable PHX_HOST is missing.
        Set it to the public hostname of the API, for example: api.simplefit.com
        """

    config :simple_fit, SimpleFitWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        # Enable IPv6 and bind on all interfaces.
        # See https://bandit.hexdocs.pm/Bandit.html#t:options/0
        ip: {0, 0, 0, 0, 0, 0, 0, 0}
      ],
      secret_key_base: secret_key_base

    # API docs are off in production unless explicitly enabled.
    config :simple_fit, :api_docs, enabled: parse_boolean.("API_DOCS_ENABLED", false)

    # Providers always use the real adapters in production, never fakes.
    # Missing credentials do not block boot; operations then fail closed
    # with :configuration_error (and an error log naming the missing keys).
    storage = storage_env.()

    if storage[:endpoint] && not String.starts_with?(storage[:endpoint], "https://") do
      raise "AWS_S3_ENDPOINT must use https:// in production"
    end

    config :simple_fit, SimpleFit.Storage, [{:adapter, SimpleFit.Storage.S3} | storage]

    # Explicit https origins only; unset = no browser origin allowed (mobile
    # and server clients are unaffected). Malformed values fail at boot.
    config :simple_fit, SimpleFitWeb.CORS,
      allowed_origins:
        SimpleFitWeb.CORS.parse_origins!(System.get_env("CORS_ALLOWED_ORIGINS"),
          require_https: true
        )

    # Encrypted email job payloads use the same secret (ADR 0011).
    config :simple_fit, SimpleFit.Email, [
      {:adapter, SimpleFit.Email.Resend},
      {:payload_key_base, secret_key_base} | email_env.()
    ]
end
