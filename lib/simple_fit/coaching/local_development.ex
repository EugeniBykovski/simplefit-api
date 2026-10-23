defmodule SimpleFit.Coaching.LocalDevelopment do
  @moduledoc """
  Whether this node runs Coach–Fighter coaching in LOCAL DEVELOPMENT mode
  (SF-81, ADR 0025): the Coach–Fighter workflow without published legal
  documents, for a developer's own machine only. `SimpleFit.Coaching.LegalPolicy`
  is the only reader.

  The mode is decided once, at boot (a supervision child started after the
  repo and before the endpoint), from facts the node can establish itself.
  An environment variable alone never turns it on. All of these must hold:

    1. the code was built with the mode allowed: `config/dev.exs` sets
       `allowed: true`. `config/test.exs` does too, for the test-only switch
       below. No production or release configuration sets it, so in a
       production build `active?/0` is `false` whatever happens at runtime;
    2. the build environment is `:dev` (`Mix.env()` at compile time) and the
       node is not an OTP release (`RELEASE_NAME` unset, Mix loaded);
    3. the developer opted in: `SIMPLEFIT_LOCAL_DEV_COACHING=enabled`, read
       by `config/runtime.exs` in the `:dev` branch only;
    4. the endpoint listens on loopback only (no `PHX_BIND_ALL`);
    5. the repo's configured host is loopback, and the server the live
       connection reached is local (`inet_server_addr()` loopback, or a
       Unix socket);
    6. the live database is one of the approved development databases
       (`config/dev.exs`: `simple_fit_dev`).

  Anything else leaves the mode off (fail closed). An opt-in that is refused
  is logged with the failed checks; an active mode is logged loudly at boot.
  """

  require Logger

  alias SimpleFit.Repo

  @allowed Application.compile_env(:simple_fit, [__MODULE__, :allowed], false) == true
  @build_env Mix.env()
  @key {__MODULE__, :active}

  @typedoc "What `evaluate/1` decides on."
  @type facts :: %{
          allowed: boolean(),
          build_env: atom(),
          release?: boolean(),
          opt_in: boolean(),
          endpoint_ip: term(),
          repo_host: term(),
          database: String.t() | nil,
          server_addr: String.t() | nil,
          approved_databases: [String.t()]
        }

  @doc "Whether LOCAL DEVELOPMENT coaching mode is active on this node."
  @spec active?() :: boolean()
  if @allowed do
    def active?, do: :persistent_term.get(@key, false) == true
  else
    # A build without the mode allowed (production) cannot answer otherwise.
    def active?, do: false
  end

  @doc false
  def child_spec(_opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  @doc false
  # Decides the mode synchronously during boot and starts no process.
  def start_link do
    _ = activate()
    :ignore
  end

  @doc """
  Evaluates the facts of this node and records the result: `:active`, or
  `{:inactive, reasons}` (no opt-in is a reason too).
  """
  @spec activate() :: :active | {:inactive, [atom()]}
  def activate do
    facts = facts()

    case evaluate(facts) do
      :ok ->
        :persistent_term.put(@key, true)

        Logger.warning(
          "LOCAL DEVELOPMENT coaching mode is ON (SF-81): Coach–Fighter sharing works " <>
            "without legal documents on database #{facts.database}. Never in production."
        )

        :active

      {:error, reasons} ->
        :persistent_term.put(@key, false)

        if facts.opt_in do
          Logger.error(
            "LOCAL DEVELOPMENT coaching mode was requested but refused: #{inspect(reasons)}"
          )
        end

        {:inactive, reasons}
    end
  end

  @doc """
  The decision, from `facts` only: `:ok` when every condition in the module
  doc holds, otherwise `{:error, reasons}` naming each failed check.
  """
  @spec evaluate(facts()) :: :ok | {:error, [atom()]}
  def evaluate(facts) do
    [
      not_allowed_in_this_build: facts.allowed == true,
      not_a_dev_build: facts.build_env == :dev,
      release: facts.release? == false,
      not_opted_in: facts.opt_in == true,
      endpoint_not_loopback: loopback_ip?(facts.endpoint_ip),
      repo_host_not_loopback: loopback_host?(facts.repo_host),
      database_server_not_local: local_server?(facts.server_addr),
      database_not_approved:
        is_binary(facts.database) and facts.database in facts.approved_databases
    ]
    |> Enum.reject(fn {_reason, ok?} -> ok? end)
    |> Enum.map(fn {reason, _ok?} -> reason end)
    |> case do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  defp facts do
    config = Application.get_env(:simple_fit, __MODULE__, [])
    endpoint = Application.get_env(:simple_fit, SimpleFitWeb.Endpoint, [])
    opt_in = config[:opt_in] == true
    {database, server_addr} = if opt_in, do: live_database(), else: {nil, :unknown}

    %{
      allowed: @allowed,
      build_env: @build_env,
      release?: System.get_env("RELEASE_NAME") != nil or not Code.ensure_loaded?(Mix),
      opt_in: opt_in,
      endpoint_ip: get_in(endpoint, [:http, :ip]),
      repo_host: repo_host(),
      database: database,
      server_addr: server_addr,
      approved_databases: config[:databases] || []
    }
  end

  defp repo_host do
    config = Repo.config()

    cond do
      config[:socket_dir] || config[:socket] -> :unix_socket
      url = config[:url] -> URI.parse(url).host
      true -> config[:hostname]
    end
  end

  # Read only after an opt-in (which only config/runtime.exs's :dev branch
  # sets): a production node never queries for the mode.
  defp live_database do
    case Repo.query("select current_database(), inet_server_addr()::text", [], log: false) do
      {:ok, %{rows: [[database, addr]]}} -> {database, addr}
      _ -> {nil, :unknown}
    end
  end

  defp loopback_ip?({127, _, _, _}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_ip?(_ip), do: false

  defp loopback_host?(:unix_socket), do: true
  defp loopback_host?(host) when host in ["localhost", "127.0.0.1", "::1", "[::1]"], do: true
  defp loopback_host?(_host), do: false

  # `inet_server_addr()` is NULL over a Unix socket.
  defp local_server?(nil), do: true
  defp local_server?("::1" <> _), do: true
  defp local_server?("127." <> _), do: true
  defp local_server?(_addr), do: false

  if Mix.env() == :test do
    @doc false
    # Test-only (compiled into the :test build alone): runs the domain under
    # a given mode. The real activation above refuses every non-:dev build.
    @spec put_active_for_test(boolean()) :: :ok
    def put_active_for_test(active?) when is_boolean(active?),
      do: :persistent_term.put(@key, active?)
  end
end
