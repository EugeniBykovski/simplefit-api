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
end
