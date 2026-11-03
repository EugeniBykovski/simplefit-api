defmodule SimpleFit.Gyms.MemberProductVersion do
  @moduledoc """
  The content of a member product (SF-101): name, description, the class
  admissions it grants (`class_credits`; none for unlimited) and how long it
  is valid once activated (`validity_days`). `draft`, `archived`,
  `published` (offered; immutable), `superseded` or `retired`, as SaaS plan
  versions.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "gym_member_product_versions" do
    field :gym_id, :binary_id
    belongs_to :product, SimpleFit.Gyms.MemberProduct
    field :version, :integer
    field :name, :string
    field :description, :string

    field :status, Ecto.Enum,
      values: [:draft, :archived, :published, :superseded, :retired],
      default: :draft

    field :class_credits, :integer
    field :validity_days, :integer
    field :published_by_user_id, :binary_id
    field :published_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    has_many :prices, SimpleFit.Gyms.MemberPriceVersion, foreign_key: :product_version_id
    timestamps(type: :utc_datetime_usec)
  end
end
