defmodule SimpleFit.Billing.Stripe.Customer do
  @moduledoc "A gym's Stripe Customer in one mode (SF-102): created once, never changed."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "stripe_customers" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :gym_id, :binary_id
    field :stripe_customer_id, :string
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
