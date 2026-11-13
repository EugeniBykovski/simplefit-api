defmodule SimpleFit.Sponsors.PartnershipPreferences do
  @moduledoc """
  An organization's partnership preferences (SF-130, ADR 0034): the interests,
  markets and goals it wants SimpleFit to know about now. One row per organization,
  created by the first save of its owner or a manager; a trigger raises `revision` on
  every update and forbids deletes. **No budget** (D-SA39) and nothing commercial.
  The application's submitted answers stay as they were submitted
  (`SimpleFit.Sponsors.ApplicationSubmission`); these never change them.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sponsor_partnership_preferences" do
    field :organization_id, :binary_id
    field :revision, :integer, default: 1, read_after_writes: true
    field :interests, {:array, :string}, default: []
    field :market_scope, :string
    field :market_countries, {:array, :string}, default: []
    field :market_cities, {:array, :string}, default: []
    field :goals, :string
    field :updated_by_user_id, :binary_id

    timestamps()
  end
end
