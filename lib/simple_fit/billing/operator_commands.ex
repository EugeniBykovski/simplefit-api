defmodule SimpleFit.Billing.OperatorCommands do
  @moduledoc """
  Whether this build may run the privileged billing commands of `mix billing.stripe`
  and `mix billing.catalog` (SF-138). Refunds, price mappings, the portal
  configuration, connected accounts and catalog publication take `--operator` and
  `--approval` from the command line, and anyone able to run a task can type someone
  else's name or any reference: neither proves authority.

  SimpleFit has no authority that can (SF-110; see `SimpleFit.Gyms.VerificationAuthority`
  for the same decision on verification review), so a production build refuses them.
  This is decided at compile time: no environment variable or runtime configuration
  turns them on. Elsewhere, `--operator` and `--approval` are unverified labels on
  local and disposable data.

  Read-only diagnostics, and reconciliation, which applies only what Stripe answers
  and names nobody, stay available.
  """

  @build Mix.env()

  @doc "Whether a build (by default this one) may run the privileged billing commands."
  @spec available?(atom()) :: boolean()
  def available?(build \\ @build), do: build != :prod

  @doc "Raises in a build where the privileged billing commands are refused."
  @spec ensure_available!(atom()) :: :ok
  def ensure_available!(build \\ @build) do
    if available?(build) do
      :ok
    else
      Mix.raise("refused: SimpleFit can't verify an operator in a production build (SF-138)")
    end
  end
end
