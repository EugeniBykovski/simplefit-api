defmodule SimpleFit.Sponsors.ApplicationSubmission do
  @moduledoc """
  One submission of a sponsor application (SF-113): exactly what the applicant
  sent, frozen. `snapshot` is a versioned, schema-tagged map built from an
  allowlist (`SimpleFit.Sponsors.ApplicationPolicy.snapshot/1`) with its SHA-256;
  the validation policy version and the accepted declaration (document, version,
  language, text hash) are recorded with it. Append-only by trigger. Not
  cryptographically signed: the hash detects accidental change, not a database
  superuser.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sponsor_application_submissions" do
    field :application_id, :binary_id
    field :sequence, :integer
    field :application_revision, :integer
    field :policy_version, :string
    field :declaration_document_id, :string
    field :declaration_version, :string
    field :declaration_language, :string
    field :declaration_content_sha256, :string
    field :snapshot, :map
    field :snapshot_sha256, :binary
    field :client_request_id, :binary_id
    field :request_sha256, :binary
    field :submitted_by_user_id, :binary_id
    field :submitted_at, :utc_datetime_usec
  end
end
