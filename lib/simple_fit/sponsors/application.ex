defmodule SimpleFit.Sponsors.Application do
  @moduledoc """
  A sponsor application (SF-113, ADR 0031): one applicant's request to become a
  sponsor. **It grants nothing** - no organization, membership, capability,
  agreement, payment or verification - in any status. Owned by the applicant's
  user id (never an email). Answers are typed columns, editable only while
  `draft` or `changes_requested` (a trigger enforces it, and raises `revision` on
  every update). What each submission said is kept separately, immutable
  (`SimpleFit.Sponsors.ApplicationSubmission`).
  """

  use Ecto.Schema

  @statuses [
    :draft,
    :submitted,
    :under_review,
    :changes_requested,
    :approved,
    :rejected,
    :withdrawn
  ]

  @type status ::
          :draft
          | :submitted
          | :under_review
          | :changes_requested
          | :approved
          | :rejected
          | :withdrawn
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sponsor_applications" do
    field :applicant_user_id, :binary_id
    field :status, Ecto.Enum, values: @statuses
    field :revision, :integer, default: 1, read_after_writes: true
    field :client_request_id, :binary_id

    field :company_name, :string
    field :website, :string
    field :country_code, :string
    field :industry, :string
    field :contact_full_name, :string
    field :contact_position, :string
    field :contact_email, :string
    field :contact_phone, :string
    field :interests, {:array, :string}, default: []
    field :market_scope, :string
    field :market_countries, {:array, :string}, default: []
    field :market_cities, {:array, :string}, default: []
    field :budget_band, :string
    field :goals, :string

    field :submitted_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec

    timestamps()
  end

  @doc "Every status (the proposed SF-107 lifecycle, D-SA02)."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Statuses in which an applicant has a current application (at most one)."
  @spec current_statuses() :: [status()]
  def current_statuses, do: [:draft, :submitted, :under_review, :changes_requested]

  @doc "Statuses in which the applicant may edit and submit."
  @spec editable_statuses() :: [status()]
  def editable_statuses, do: [:draft, :changes_requested]
end
