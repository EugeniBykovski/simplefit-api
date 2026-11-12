defmodule SimpleFit.Sponsors.ProposalSubmission do
  @moduledoc """
  One submission of a partnership proposal (SF-130): an immutable, schema-tagged
  snapshot of exactly what was sent, with its SHA-256, the policy version and the
  idempotency key. Append-only.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sponsor_partnership_proposal_submissions" do
    field :proposal_id, :binary_id
    field :sequence, :integer
    field :proposal_revision, :integer
    field :policy_version, :string
    field :snapshot, :map, redact: true
    field :snapshot_sha256, :binary
    field :client_request_id, :binary_id
    field :request_sha256, :binary
    field :submitted_by_user_id, :binary_id
    field :submitted_at, :utc_datetime_usec
  end
end
