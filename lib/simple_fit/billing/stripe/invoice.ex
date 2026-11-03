defmodule SimpleFit.Billing.Stripe.Invoice do
  @moduledoc """
  A Stripe invoice of a gym's customer as last reconciled (SF-102): status,
  amounts in minor units, period, Stripe-hosted URLs, refunded amount and
  dispute flag. Never computed or rendered as a PDF by SimpleFit; a draft or
  open invoice is never shown as paid.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @statuses [:draft, :open, :paid, :uncollectible, :void]
  @payment_statuses [
    :requires_action,
    :requires_payment_method,
    :processing,
    :succeeded,
    :canceled
  ]

  @spec statuses() :: [atom()]
  def statuses, do: @statuses
  @spec payment_statuses() :: [atom()]
  def payment_statuses, do: @payment_statuses

  schema "stripe_invoices" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :gym_id, :binary_id
    field :subscription_id, :binary_id
    field :stripe_invoice_id, :string
    field :stripe_subscription_id, :string
    field :number, :string
    field :status, Ecto.Enum, values: @statuses
    field :payment_status, Ecto.Enum, values: @payment_statuses
    field :currency, :string
    field :amount_due, :integer
    field :amount_paid, :integer
    field :amount_remaining, :integer
    field :total, :integer
    field :amount_refunded, :integer, default: 0
    field :disputed, :boolean, default: false
    field :billing_reason, :string
    field :period_start, :utc_datetime_usec
    field :period_end, :utc_datetime_usec
    field :hosted_invoice_url, :string, redact: true
    field :invoice_pdf, :string, redact: true
    field :paid_at, :utc_datetime_usec
    field :provider_created_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0
    field :next_payment_attempt_at, :utc_datetime_usec
    field :synced_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
