defmodule SimpleFit.Billing.Plan do
  @moduledoc "A SimpleFit SaaS plan's stable identity (`starter`, `growth`, ...); its content is versioned."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "saas_plans" do
    field :key, :string
    has_many :versions, SimpleFit.Billing.PlanVersion
    timestamps(type: :utc_datetime_usec)
  end
end
