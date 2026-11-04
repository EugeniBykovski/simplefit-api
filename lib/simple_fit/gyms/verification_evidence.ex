defmodule SimpleFit.Gyms.VerificationEvidence do
  @moduledoc """
  A document of a business-verification application (SF-103), in private
  storage under a key the server built
  (`gyms/<gym>/business-verification/<application>/<evidence>`). Internal to
  `SimpleFit.Gyms`.

  `pending_upload` until the server has read the object's size and type
  from storage (`SimpleFit.Storage.stat/2`) and found them equal to what it
  allowed; then `uploaded`. `removed` when the owner took it out before
  submitting. Once part of a submission (`submitted_revision`), it is
  frozen. The object key never leaves the server.
  """

  use Ecto.Schema

  @type status :: :pending_upload | :uploaded | :removed
  @type kind :: :registration_extract | :proof_of_address | :other

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          application_id: Ecto.UUID.t() | nil,
          kind: kind() | nil,
          status: status() | nil,
          object_key: String.t() | nil,
          content_type: String.t() | nil,
          byte_size: pos_integer() | nil,
          file_name: String.t() | nil,
          created_by_user_id: Ecto.UUID.t() | nil,
          upload_expires_at: DateTime.t() | nil,
          uploaded_at: DateTime.t() | nil,
          removed_at: DateTime.t() | nil,
          submitted_revision: pos_integer() | nil,
          object_deleted_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_verification_evidence" do
    field :gym_id, :binary_id
    field :application_id, :binary_id
    field :kind, Ecto.Enum, values: [:registration_extract, :proof_of_address, :other]
    field :status, Ecto.Enum, values: [:pending_upload, :uploaded, :removed]
    field :object_key, :string, redact: true
    field :content_type, :string
    field :byte_size, :integer
    field :file_name, :string, redact: true
    field :created_by_user_id, :binary_id
    field :upload_expires_at, :utc_datetime_usec
    field :uploaded_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec
    field :submitted_revision, :integer
    field :object_deleted_at, :utc_datetime_usec

    timestamps()
  end
end
