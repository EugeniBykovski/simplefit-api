defmodule SimpleFit.Billing.Stripe.Refund do
  @moduledoc """
  A refund of a gym's SaaS invoice (SF-102): `operator` (requested by a
  SimpleFit operator under an approval, full amount only) or `provider`
  (seen at Stripe). Its status is Stripe's, as last reconciled.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @statuses [:requested, :pending, :requires_action, :succeeded, :failed, :canceled]

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  schema "stripe_refunds" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :gym_id, :binary_id
    field :invoice_id, :binary_id
    field :stripe_refund_id, :string
    field :idempotency_key, :binary_id
    field :origin, Ecto.Enum, values: [:operator, :provider]
    field :status, Ecto.Enum, values: @statuses
    field :amount_minor, :integer
    field :currency, :string
    field :reason, :string
    field :requested_by, :string
    field :approval_reference, :string
    field :synced_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
