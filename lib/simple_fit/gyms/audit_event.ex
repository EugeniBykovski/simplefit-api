defmodule SimpleFit.Gyms.AuditEvent do
  @moduledoc """
  An append-only record of a committed gym transition (ADR 0026, D-G18):
  who (`actor_user_id`), what (`event_type`), which staff membership, the
  roles involved and the end reason. Nothing else: no names, emails,
  tokens or profile data. Written by `SimpleFit.Gyms` in the same
  transaction as the transition it records, so only committed actions are
  recorded. The database rejects updates; no foreign keys, so events outlive
  the rows they name (retention waits for an approved policy).
  """

  use Ecto.Schema

  alias SimpleFit.Gyms.StaffMembership

  @type event_type ::
          :gym_created
          | :staff_membership_created
          | :ownership_transferred
          | :staff_membership_ended

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          actor_user_id: Ecto.UUID.t() | nil,
          event_type: event_type() | nil,
          staff_membership_id: Ecto.UUID.t() | nil,
          from_role: StaffMembership.role() | nil,
          to_role: StaffMembership.role() | nil,
          reason: StaffMembership.ended_reason() | nil,
          occurred_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gym_audit_events" do
    field :gym_id, :binary_id
    field :actor_user_id, :binary_id

    field :event_type, Ecto.Enum,
      values: [
        :gym_created,
        :staff_membership_created,
        :ownership_transferred,
        :staff_membership_ended
      ]

    field :staff_membership_id, :binary_id
    field :from_role, Ecto.Enum, values: StaffMembership.roles()
    field :to_role, Ecto.Enum, values: StaffMembership.roles()

    field :reason, Ecto.Enum,
      values: [:left, :removed, :transferred, :account_deleted, :gym_closed]

    field :occurred_at, :utc_datetime_usec
  end
end
