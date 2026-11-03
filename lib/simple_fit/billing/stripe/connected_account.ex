defmodule SimpleFit.Billing.Stripe.ConnectedAccount do
  @moduledoc """
  A gym's Stripe Connect account (SF-102 foundation for gym member
  payments): linked by an operator, its capabilities synced from Stripe.
  No KYC document is stored, and nothing creates a charge on it.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "stripe_connected_accounts" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :gym_id, :binary_id
    field :stripe_account_id, :string
    field :charges_enabled, :boolean, default: false
    field :payouts_enabled, :boolean, default: false
    field :details_submitted, :boolean, default: false
    field :requirements_due_count, :integer, default: 0
    field :disabled_reason, :string
    field :linked_by, :string
    field :last_synced_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
