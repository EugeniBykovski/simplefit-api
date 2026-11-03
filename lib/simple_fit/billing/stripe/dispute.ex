defmodule SimpleFit.Billing.Stripe.Dispute do
  @moduledoc "A chargeback/dispute of a gym's SaaS invoice as last reconciled from Stripe (SF-102); never a refund."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "stripe_disputes" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :gym_id, :binary_id
    field :invoice_id, :binary_id
    field :stripe_dispute_id, :string
    field :status, :string
    field :reason, :string
    field :amount_minor, :integer
    field :currency, :string
    field :synced_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
