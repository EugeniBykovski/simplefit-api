defmodule SimpleFit.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias SimpleFit.Accounts.{EmailAuth, Sessions}
  alias SimpleFit.Identity.{Apple, Google}

  @impl true
  def start(_type, _args) do
    # Logs, error tracking and tracing (handlers only; no backend is required).
    :ok = SimpleFit.Observability.setup()

    # Fail at boot on a missing or inconsistent session policy (ADR 0010).
    _policy = Sessions.config!()
    # Same for email authentication and its key material (ADR 0012).
    _email_auth = EmailAuth.config!()
    # Google sign-in is optional (ADR 0013): warn, never fail, when unset.
    :ok = Google.warn_if_not_configured()
    # So is Sign in with Apple (ADR 0014).
    :ok = Apple.warn_if_not_configured()

    children = [
      SimpleFitWeb.Telemetry,
      SimpleFit.Repo,
      {Oban, Application.fetch_env!(:simple_fit, Oban)},
      # Google ID-token signing keys (ADR 0013).
      Google.Keys,
      # Sign in with Apple identity-token signing keys (ADR 0014).
      Apple.Keys,
      # Start to serve requests, typically the last entry
      SimpleFitWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SimpleFit.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SimpleFitWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
