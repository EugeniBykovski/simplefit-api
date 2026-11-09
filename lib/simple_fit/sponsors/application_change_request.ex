defmodule SimpleFit.Sponsors.ApplicationChangeRequest do
  @moduledoc """
  An operator's request for changes to a submitted sponsor application (SF-114):
  a reason code, the answers to revisit and a plain-text message to the applicant.
  At most one open per application; resolved by the next submission, never edited.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sponsor_application_change_requests" do
    field :application_id, :binary_id
    field :requested_by_operator_id, :binary_id
    field :reason_code, :string
    field :fields, {:array, :string}
    field :message, :string, redact: true
    field :application_revision, :integer
    field :requested_at, :utc_datetime_usec
    field :resolved_by_submission_id, :binary_id
    field :resolved_at, :utc_datetime_usec
  end
end
