defmodule SimpleFit.Operators.Grant do
  @moduledoc """
  One permission held by one operator. Exactly one source: an operator (never the
  grantee) or a signed ceremony. Only revocation changes a row.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "operator_permission_grants" do
    field :operator_id, :binary_id
    field :permission, :string
    field :granted_by_operator_id, :binary_id
    field :ceremony_id, :binary_id
    field :reason_code, :string
    field :operation_id, :binary_id
    field :granted_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :revoked_by_operator_id, :binary_id
    field :revoke_reason_code, :string
  end
end
