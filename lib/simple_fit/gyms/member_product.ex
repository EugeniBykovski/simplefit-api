defmodule SimpleFit.Gyms.MemberProduct do
  @moduledoc """
  A product a gym sells to its members (SF-101): a stable key and type
  (`single_visit`, `class_pack`, `unlimited_period`) owned by one gym;
  `active` or `retired`. Its content and prices are versioned. Never related
  to SimpleFit's SaaS plans, to gym membership itself or to staff.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @types [:single_visit, :class_pack, :unlimited_period]

  @spec types() :: [atom()]
  def types, do: @types

  schema "gym_member_products" do
    field :gym_id, :binary_id
    field :key, :string
    field :product_type, Ecto.Enum, values: @types
    field :status, Ecto.Enum, values: [:active, :retired], default: :active
    field :client_request_id, :binary_id
    field :created_by_user_id, :binary_id
    field :retired_at, :utc_datetime_usec
    has_many :versions, SimpleFit.Gyms.MemberProductVersion, foreign_key: :product_id
    timestamps(type: :utc_datetime_usec)
  end
end
