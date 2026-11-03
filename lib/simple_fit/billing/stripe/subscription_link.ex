defmodule SimpleFit.Billing.Stripe.SubscriptionLink do
  @moduledoc """
  The Stripe Subscription behind an SF-101 gym subscription (SF-102),
  created only from a verified, completed checkout of that subscription.
  Holds the provider state last reconciled; `discrepancy` names why it could
  not be applied (a code).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @provider_statuses [
    :incomplete,
    :incomplete_expired,
    :trialing,
    :active,
    :past_due,
    :canceled,
    :unpaid,
    :paused
  ]

  @spec provider_statuses() :: [atom()]
  def provider_statuses, do: @provider_statuses

  schema "stripe_subscriptions" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :gym_id, :binary_id
    field :subscription_id, :binary_id
    field :stripe_subscription_id, :string
    field :stripe_customer_id, :string
    field :provider_status, Ecto.Enum, values: @provider_statuses
    field :cancel_at_period_end, :boolean, default: false
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :latest_invoice_id, :string
    field :discrepancy, :string
    field :synced_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
