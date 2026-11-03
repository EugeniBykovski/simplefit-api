defmodule SimpleFit.Billing.ActivationEvidence do
  @moduledoc """
  Verified evidence that a subscription may become active: written only by
  `SimpleFit.Billing.Activation` from a configured trusted provider's
  verification, never from client input. Unique per provider reference;
  never changed.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "billing_activation_evidence" do
    field :provider, :string
    field :provider_reference, :string
    field :subject, Ecto.Enum, values: [:saas_subscription, :member_product_subscription]
    field :period_start, :utc_datetime_usec
    field :period_end, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
