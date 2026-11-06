defmodule SimpleFit.Gyms.VerificationAuthority do
  @moduledoc """
  Who may review gym business verification (SF-136, SF-104 F-03; ADR 0026
  amendment SF-136). Every call of `SimpleFit.Gyms.VerificationReview` asks this
  module first.

  **SimpleFit has no authority that can prove an operator's identity**, so
  production has none: `Disabled` answers `:review_disabled` to everything. An
  email address, on a list or not, proves nothing: anyone able to run a task can
  type someone else's.

  The backend is chosen at compile time and a production build refuses any other,
  so no environment variable, runtime configuration or deployment setting can
  turn review on. Enabling it takes a real authority (SF-110), a code change and a
  review. `Local`, the fixture for tests and local development, is not even
  compiled into a production build, and what it attributes is recorded as
  `local_fixture`, never as a trusted operator.

  An authority must, on every call and without caching: verify the credential,
  answer for the operator's current grants and revocation, and return an immutable
  actor id and the person's user id.
  """

  alias SimpleFit.Gyms.OperatorPrincipal

  @type permission ::
          :read_queue
          | :read_application
          | :read_evidence
          | :approve
          | :request_changes
          | :reject
          | :revoke

  @type error :: :review_disabled | :unauthenticated | {:forbidden, :operator}

  @callback available?() :: boolean()
  @callback ambient_credential() :: term()
  @callback authenticate(term(), permission()) :: {:ok, OperatorPrincipal.t()} | {:error, error()}

  @backend Application.compile_env(
             :simple_fit,
             [__MODULE__, :backend],
             SimpleFit.Gyms.VerificationAuthority.Disabled
           )

  if Mix.env() == :prod and @backend != SimpleFit.Gyms.VerificationAuthority.Disabled do
    raise "SF-136: a production build has no verification review authority (see ADR 0026)"
  end

  # No spec: the backend is a compile-time constant, so each build's answer is fixed
  # and a `boolean()` contract is too wide for Dialyzer. The callback states the type.
  @doc "Whether this build has any authority at all."
  def available?, do: @backend.available?()

  @doc """
  The credential a command-line caller holds, from the authority and never from
  the command line: nothing a caller types names an operator.
  """
  @spec ambient_credential() :: term()
  def ambient_credential, do: @backend.ambient_credential()

  @doc "Authenticates `credential` and checks `permission`, now, with no cache."
  @spec authenticate(term(), permission()) :: {:ok, OperatorPrincipal.t()} | {:error, error()}
  def authenticate(credential, permission), do: @backend.authenticate(credential, permission)
end
