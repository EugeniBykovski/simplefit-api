defmodule SimpleFit.Sponsors.OrganizationEvent do
  @moduledoc """
  Append-only business history of a sponsor organization (SF-112): provisioning,
  membership and status changes, with the authority that made them. Ids and codes
  only. Separate from `operator_audit_events` (SF-110/111): this is the
  organization's own record, which a later task may show to its owner; operator
  audit is platform-internal.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sponsor_organization_events" do
    field :organization_id, :binary_id
    field :occurred_at, :utc_datetime_usec
    field :event, :string

    field :authority, Ecto.Enum,
      values: [:sponsor_application, :local_fixture, :organization_member, :system]

    field :actor_user_id, :binary_id
    field :membership_id, :binary_id
    field :subject_user_id, :binary_id
    field :role, :string
    field :from_state, :string
    field :to_state, :string
    field :reason_code, :string
    field :request_id, :string
  end
end
