defmodule SimpleFit.Billing.Stripe.Checkout do
  @moduledoc """
  A Stripe-hosted Checkout Session for one pending SaaS subscription intent
  (SF-102): `creating` (requested; its answer may have been lost, so a retry
  reuses the idempotency key), `open`, `completed`, `expired` or `failed`.
  A completed checkout is not a payment: only reconciled invoice evidence
  activates the subscription.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "stripe_checkouts" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :gym_id, :binary_id
    field :subscription_id, :binary_id
    field :idempotency_key, :binary_id
    field :stripe_session_id, :string
    field :url, :string, redact: true
    field :status, Ecto.Enum, values: [:creating, :open, :completed, :expired, :failed]
    field :expires_at, :utc_datetime_usec
    field :requested_by_user_id, :binary_id
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
