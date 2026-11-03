defmodule SimpleFit.Billing.Stripe.PriceMapping do
  @moduledoc """
  The Stripe Product/Price created for one SF-101 price version in one mode
  (SF-102), with the amount, currency and interval it was created for:
  checkout refuses a mapping that disagrees with its price version.
  Immutable.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "stripe_prices" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :price_version_id, :binary_id
    field :stripe_product_id, :string
    field :stripe_price_id, :string
    field :currency, :string
    field :amount_minor, :integer
    field :interval, Ecto.Enum, values: [:month, :year]
    field :mapped_by, :string
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
