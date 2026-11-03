defmodule SimpleFit.Billing.PlanVersion do
  @moduledoc """
  The contractual content of a SaaS plan (SF-101): `draft` (editable;
  `archived` and restored freely), `published` (offered; immutable),
  `superseded` by a newer published version (still referenced by its
  subscriptions) or `retired`. `price_source` records where its prices come
  from; a published version records the approval it was published under.
  """
  use Ecto.Schema

  alias SimpleFit.Billing.{Plan, PlanEntitlement, PriceVersion}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @statuses [:draft, :archived, :published, :superseded, :retired]
  @price_sources [:approved_design, :product_decision, :provisional]

  @spec statuses() :: [atom()]
  def statuses, do: @statuses
  @spec price_sources() :: [atom()]
  def price_sources, do: @price_sources

  schema "saas_plan_versions" do
    belongs_to :plan, Plan
    field :version, :integer
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :price_source, Ecto.Enum, values: @price_sources
    field :proposed_trial_days, :integer
    field :approval_reference, :string
    field :published_by, :string
    field :published_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    has_many :prices, PriceVersion
    has_many :entitlements, PlanEntitlement
    timestamps(type: :utc_datetime_usec)
  end
end
