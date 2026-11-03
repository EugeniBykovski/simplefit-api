defmodule SimpleFit.Billing.GymSubscription do
  @moduledoc """
  A gym's SimpleFit SaaS subscription (the gym is the subscriber, not its
  owner as a person): `pending_activation` (an intent, no access), `active`,
  `cancellation_scheduled` (ends at the period end), `cancelled` or
  `expired`. It references the price version the gym agreed to, which never
  changes when a newer plan version is published.

  SF-102: a subscription paid through Stripe is reconciled from provider
  state (`SimpleFit.Billing.Reconciliation`); `provider_initiated` is the
  cancel reason when the provider ended it outside SimpleFit.
  """
  use Ecto.Schema

  alias SimpleFit.Billing.{ActivationEvidence, PlanVersion, PriceVersion}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @statuses [:pending_activation, :active, :cancellation_scheduled, :cancelled, :expired]

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  schema "gym_saas_subscriptions" do
    field :gym_id, :binary_id
    belongs_to :plan_version, PlanVersion
    belongs_to :price_version, PriceVersion
    field :status, Ecto.Enum, values: @statuses, default: :pending_activation
    field :client_request_id, :binary_id
    field :requested_by_user_id, :binary_id
    field :requested_at, :utc_datetime_usec
    belongs_to :activation_evidence, ActivationEvidence
    field :activated_at, :utc_datetime_usec
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :cancel_mode, Ecto.Enum, values: [:immediate, :period_end]
    field :cancel_reason, Ecto.Enum, values: [:requested_by_gym, :gym_closed, :provider_initiated]
    field :cancellation_requested_at, :utc_datetime_usec
    field :cancellation_effective_at, :utc_datetime_usec
    field :cancelled_by_user_id, :binary_id
    field :ended_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
