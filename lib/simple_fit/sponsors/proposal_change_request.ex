defmodule SimpleFit.Sponsors.ProposalChangeRequest do
  @moduledoc """
  An operator's request for changes to a partnership proposal (SF-130): a reason
  code (internal), the answers to revisit and a plain-text message to the
  organization. At most one open per proposal; resolved by the next submission,
  never edited.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sponsor_partnership_change_requests" do
    field :proposal_id, :binary_id
    field :requested_by_operator_id, :binary_id
    field :reason_code, :string
    field :fields, {:array, :string}
    field :message, :string, redact: true
    field :proposal_revision, :integer
    field :requested_at, :utc_datetime_usec
    field :resolved_by_submission_id, :binary_id
    field :resolved_at, :utc_datetime_usec
  end
end
