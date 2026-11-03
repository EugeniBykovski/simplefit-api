defmodule SimpleFit.Billing.Stripe.VerifiedInvoice do
  @moduledoc """
  A paid Stripe invoice that reconciliation fetched from the Stripe API and
  matched to a gym subscription (SF-102): the only payload
  `SimpleFit.Billing.Stripe.Provider` verifies. Built in-process, never
  from client or webhook input.
  """

  @enforce_keys [:mode, :invoice_id, :status, :period_start, :period_end]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mode: :test | :live,
          invoice_id: String.t(),
          status: :paid,
          period_start: DateTime.t(),
          period_end: DateTime.t()
        }
end
