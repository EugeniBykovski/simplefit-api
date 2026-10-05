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

case config_env() do
  :dev ->
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
    config :simple_fit, SimpleFit.Email, [{:adapter, SimpleFit.Email.Resend} | email_env.()]
end
