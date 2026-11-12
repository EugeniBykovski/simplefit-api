defmodule SimpleFit.Sponsors.Proposal do
  @moduledoc """
  A sponsor organization's partnership proposal (SF-130, ADR 0034): a **nonbinding**
  general inquiry to SimpleFit (`kind` `general_inquiry`; no opportunity inventory
  exists, D-SA21). It grants nothing in any status - no payment, campaign, placement,
  advertising entitlement, exposure guarantee or access to athlete or gym data -
  and names no athlete, gym or person. `accepted` means only that SimpleFit will
  follow up.

  Answers are typed columns, editable only while `draft` or `changes_requested` (a
  trigger enforces it with the lifecycle, and raises `revision` on every update). What
  each submission said is kept separately and immutably
  (`SimpleFit.Sponsors.ProposalSubmission`).
  """

  use Ecto.Schema

  @statuses [
    :draft,
    :submitted,
    :under_review,
    :changes_requested,
    :accepted,
    :declined,
    :withdrawn
  ]

  @type status ::
          :draft
          | :submitted
          | :under_review
          | :changes_requested
          | :accepted
          | :declined
          | :withdrawn
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sponsor_partnership_proposals" do
    field :organization_id, :binary_id
    field :created_by_user_id, :binary_id
    field :kind, Ecto.Enum, values: [:general_inquiry], default: :general_inquiry
    field :status, Ecto.Enum, values: @statuses
    field :revision, :integer, default: 1, read_after_writes: true
    field :client_request_id, :binary_id
    field :request_sha256, :binary, redact: true
    field :withdrawal_request_id, :binary_id

    field :title, :string
    field :interests, {:array, :string}, default: []
    field :market_scope, :string
    field :market_countries, {:array, :string}, default: []
    field :market_cities, {:array, :string}, default: []
    field :summary, :string, redact: true

    field :submitted_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec

    timestamps()
  end

  @doc "Every status (D-SA37)."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Statuses that are still open (not decided or withdrawn)."
  @spec open_statuses() :: [status()]
  def open_statuses, do: [:draft, :submitted, :under_review, :changes_requested]

  @doc "Statuses in which the organization may edit and submit."
  @spec editable_statuses() :: [status()]
  def editable_statuses, do: [:draft, :changes_requested]
end
