defmodule SimpleFit.Operators.Credential do
  @moduledoc """
  A WebAuthn credential of an operator: public material only (the COSE public key, the credential id, the signature counter). A credential id is unique
  forever, so a revoked key can't be registered again.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "operator_credentials" do
    field :operator_id, :binary_id
    field :credential_id, :binary, redact: true
    field :cose_key, :binary, redact: true
    field :sign_count, :integer, default: 0
    field :aaguid, :binary
    field :label, :string
    field :backup_eligible, :boolean
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :revoked_reason, :string

    timestamps()
  end
end
