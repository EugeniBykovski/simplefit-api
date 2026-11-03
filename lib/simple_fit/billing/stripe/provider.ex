defmodule SimpleFit.Billing.Stripe.Provider do
  @moduledoc """
  Stripe as a trusted activation provider (SF-102;
  `SimpleFit.Billing.Activation`). Registered in `trusted_providers` only
  when the Stripe integration is configured (`config/runtime.exs`).

  Its payload is never a request or webhook body: it is a
  `SimpleFit.Billing.Stripe.VerifiedInvoice` that reconciliation builds
  after fetching the invoice from the Stripe API with SimpleFit's key and
  checking it against the gym's customer, its Stripe subscription, the
  subscription's price version (currency and amount), its mode and its
  status (`paid`). `verify/1` answers the evidence reference (`<mode>:<invoice
  id>`, unique, so one paid invoice never activates or renews twice) and the
  paid period from the invoice's subscription line.
  """

  @behaviour SimpleFit.Billing.Activation

  alias SimpleFit.Billing.Stripe.VerifiedInvoice

  @impl true
  def verify(%VerifiedInvoice{
        mode: mode,
        invoice_id: "in_" <> _ = invoice_id,
        status: :paid,
        period_start: %DateTime{} = from,
        period_end: %DateTime{} = to
      })
      when mode in [:test, :live],
      do: {:ok, %{reference: "#{mode}:#{invoice_id}", period_start: from, period_end: to}}

  def verify(_payload), do: {:error, :invalid_request}
end
