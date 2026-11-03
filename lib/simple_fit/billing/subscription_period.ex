defmodule SimpleFit.Billing.SubscriptionPeriod do
  @moduledoc "A billing period a gym SaaS subscription was activated or renewed for, from verified evidence; never changed."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "gym_saas_subscription_periods" do
    field :gym_id, :binary_id
    field :subscription_id, :binary_id
    field :period_start, :utc_datetime_usec
    field :period_end, :utc_datetime_usec
    field :source, Ecto.Enum, values: [:activation, :renewal]
    field :activation_evidence_id, :binary_id
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
