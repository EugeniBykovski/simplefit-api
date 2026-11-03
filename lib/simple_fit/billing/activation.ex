defmodule SimpleFit.Billing.Activation do
  @moduledoc """
  The payment verification boundary (SF-101; ADR 0005; SF-82 08 T22).

  A subscription (a gym's SaaS subscription or a member product
  subscription) becomes `active` only from evidence a **trusted provider**
  verified. A trusted provider is a module implementing this behaviour and
  listed in the application configuration:

      config :simple_fit, SimpleFit.Billing, trusted_providers: [MyProvider]

  No payment provider is selected yet (D-G10), so the list is empty in
  every deployed environment and **nothing can activate a subscription**:
  `pending_activation` stays an intent with no access. There is no HTTP
  endpoint that accepts a receipt, a payment status or an activation from a
  client, and a provider can never be named by a request. Only the test
  environment registers a test provider (in `test/support`), and
  `config/runtime.exs` refuses to boot production with any provider whose
  module is not a production adapter.

  A provider's `verify/1` receives the provider's own payload (for example
  a webhook body it already authenticated) and answers the verified
  reference and paid period, or a `SimpleFit.Provider` error. The evidence
  row is unique per provider and reference: a replayed provider event
  activates nothing twice.
  """

  alias SimpleFit.Billing.ActivationEvidence
  alias SimpleFit.Repo

  @type verified :: %{
          reference: String.t(),
          period_start: DateTime.t(),
          period_end: DateTime.t()
        }

  @doc "Verifies a provider payload: the provider's reference and the paid period."
  @callback verify(payload :: term()) :: {:ok, verified()} | {:error, SimpleFit.Provider.error()}

  @doc "The providers this environment trusts (none outside tests)."
  @spec trusted_providers() :: [module()]
  def trusted_providers,
    do:
      :simple_fit
      |> Application.get_env(SimpleFit.Billing, [])
      |> Keyword.get(:trusted_providers, [])

  @doc """
  Verifies `payload` with `provider` and records the evidence for `subject`
  inside the caller's transaction. Errors: `:untrusted_provider` (not
  configured: always so in deployed environments), the provider's error, or
  `:evidence_replayed` (this reference was already used).
  """
  @spec record(module(), term(), :saas_subscription | :member_product_subscription, DateTime.t()) ::
          {:ok, ActivationEvidence.t()}
          | {:error,
             :untrusted_provider
             | :evidence_replayed
             | :invalid_evidence
             | SimpleFit.Provider.error()}
  def record(provider, payload, subject, now) do
    true = Repo.in_transaction?()

    with :ok <- trusted(provider),
         {:ok, verified} <- provider.verify(payload),
         :ok <- valid(verified) do
      %ActivationEvidence{
        provider: inspect(provider),
        provider_reference: verified.reference,
        subject: subject,
        period_start: usec(verified.period_start),
        period_end: usec(verified.period_end),
        verified_at: usec(now)
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:provider, :provider_reference],
        name: :billing_activation_evidence_reference_index
      )
      |> Repo.insert(log: false)
      |> case do
        {:ok, evidence} -> {:ok, evidence}
        {:error, _} -> {:error, :evidence_replayed}
      end
    end
  end

  defp trusted(provider) do
    if is_atom(provider) and provider in trusted_providers(),
      do: :ok,
      else: {:error, :untrusted_provider}
  end

  defp valid(%{
         reference: reference,
         period_start: %DateTime{} = from,
         period_end: %DateTime{} = to
       })
       when is_binary(reference) and byte_size(reference) in 1..200 do
    if DateTime.compare(to, from) == :gt, do: :ok, else: {:error, :invalid_evidence}
  end

  defp valid(_), do: {:error, :invalid_evidence}

  # A provider may answer in whole seconds; the columns hold microseconds.
  defp usec(%DateTime{microsecond: {us, _}} = at), do: %{at | microsecond: {us, 6}}
end
