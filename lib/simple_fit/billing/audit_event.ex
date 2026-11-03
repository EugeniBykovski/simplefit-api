defmodule SimpleFit.Billing.AuditEvent do
  @moduledoc "A platform catalog event (plan drafted, priced, published, retired): ids, counts and the operator's name only."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "billing_audit_events" do
    field :event_type, Ecto.Enum,
      values: [
        :saas_plan_created,
        :saas_plan_version_drafted,
        :saas_plan_version_updated,
        :saas_plan_version_archived,
        :saas_plan_version_restored,
        :saas_plan_version_published,
        :saas_plan_version_retired,
        :saas_price_versions_set
      ]

    field :actor, :string
    field :plan_id, :binary_id
    field :plan_version_id, :binary_id
    field :approval_reference, :string
    field :price_count, :integer
    field :occurred_at, :utc_datetime_usec
  end
end
