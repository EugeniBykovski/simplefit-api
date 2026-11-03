defmodule SimpleFit.Gyms.MemberPriceVersion do
  @moduledoc """
  One price of a member product version in a currency (SF-101): integer
  minor units, append-only. The latest `sequence` per currency is current
  for new subscriptions; earlier ones stay with the subscriptions that
  agreed to them.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "gym_member_price_versions" do
    field :gym_id, :binary_id
    belongs_to :product_version, SimpleFit.Gyms.MemberProductVersion
    field :currency, :string
    field :amount_minor, :integer
    field :sequence, :integer
    field :client_request_id, :binary_id
    field :created_by_user_id, :binary_id
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
