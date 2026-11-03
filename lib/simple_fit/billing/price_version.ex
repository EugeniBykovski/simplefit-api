defmodule SimpleFit.Billing.PriceVersion do
  @moduledoc """
  One price of a SaaS plan version for an interval and a currency: `fixed`
  (integer minor units, zero allowed and meaning free) or `quote_required`
  (no amount: Enterprise is priced by a quote, never as zero). Written only
  while its plan version is a draft; never updated.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "saas_price_versions" do
    belongs_to :plan_version, SimpleFit.Billing.PlanVersion
    field :interval, Ecto.Enum, values: [:month, :year]
    field :currency, :string
    field :pricing, Ecto.Enum, values: [:fixed, :quote_required]
    field :amount_minor, :integer
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
