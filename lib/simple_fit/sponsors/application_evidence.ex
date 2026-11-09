defmodule SimpleFit.Sponsors.ApplicationEvidence do
  @moduledoc """
  A document attached to a sponsor application (SF-114, ADR 0032), in private
  storage under a key the server built
  (`sponsors/applications/<application>/evidence/<evidence>`). `pending_upload`
  until the server read the object's size and type from storage with a HEAD
  (`SimpleFit.Storage.stat/2`) and found exactly what it allowed; then `uploaded`.
  `removed` by the owner, when replaced, or when abandoned. Once part of a
  submission it is frozen. **Never scanned**: no malware scanner exists (D-SA09).
  The object key and file name never leave the server or the logs.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sponsor_application_evidence" do
    field :application_id, :binary_id
    field :kind, Ecto.Enum, values: [:logo, :brand_deck, :campaign_brief, :other]
    field :status, Ecto.Enum, values: [:pending_upload, :uploaded, :removed]
    field :object_key, :string, redact: true
    field :content_type, :string
    field :byte_size, :integer
    field :file_name, :string, redact: true
    field :created_by_user_id, :binary_id
    field :upload_expires_at, :utc_datetime_usec
    field :uploaded_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec
    field :removed_reason, :string
    field :submission_id, :binary_id
    field :object_deleted_at, :utc_datetime_usec

    timestamps()
  end
end
