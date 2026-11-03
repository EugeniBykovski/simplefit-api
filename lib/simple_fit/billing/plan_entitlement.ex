defmodule SimpleFit.Billing.PlanEntitlement do
  @moduledoc "A feature a SaaS plan version includes (a registry key), with an explicit limit where approved."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "saas_plan_entitlements" do
    belongs_to :plan_version, SimpleFit.Billing.PlanVersion
    field :feature_key, :string
    field :quantity_limit, :integer
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
