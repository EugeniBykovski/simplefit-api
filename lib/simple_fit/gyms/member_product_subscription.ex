defmodule SimpleFit.Gyms.MemberProductSubscription do
  @moduledoc """
  A member's pass or membership product at their gym (SF-101): the same
  lifecycle as a SaaS subscription (`pending_activation`, `active`,
  `cancellation_scheduled`, `cancelled`, `expired`), referencing the product
  and price version the member chose. An intent grants nothing; no credit
  is issued or debited.
  """
  use Ecto.Schema

  alias SimpleFit.Gyms.{Member, MemberPriceVersion, MemberProductVersion}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @statuses [:pending_activation, :active, :cancellation_scheduled, :cancelled, :expired]

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  schema "gym_member_product_subscriptions" do
    field :gym_id, :binary_id
    belongs_to :gym_member, Member
    belongs_to :product_version, MemberProductVersion
    belongs_to :price_version, MemberPriceVersion
    field :status, Ecto.Enum, values: @statuses, default: :pending_activation
    field :client_request_id, :binary_id
    field :requested_by_user_id, :binary_id
    field :requested_at, :utc_datetime_usec
    field :activation_evidence_id, :binary_id
    field :activated_at, :utc_datetime_usec
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :cancel_mode, Ecto.Enum, values: [:immediate, :period_end]

    field :cancel_reason, Ecto.Enum,
      values: [:requested_by_member, :requested_by_staff, :membership_ended, :gym_closed]

    field :cancellation_requested_at, :utc_datetime_usec
    field :cancellation_effective_at, :utc_datetime_usec
    field :cancelled_by_user_id, :binary_id
    field :ended_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
