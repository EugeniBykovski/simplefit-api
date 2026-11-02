defmodule SimpleFit.Gyms.AuditEvent do
  @moduledoc """
  An append-only record of a committed gym transition (ADR 0026, D-G18):
  who (`actor_user_id`), what (`event_type`), which staff membership, staff
  invitation, gym membership or member invitation (SF-95), the roles
  involved, the end reason and the new value of a boolean setting
  (`enabled`, auto-approval); for the timetable (SF-97) the venue, class
  template, series or occurrence and how many occurrences a series change
  touched (`occurrence_count`). Nothing else: no names, emails, join codes,
  tokens, titles, times or profile data. Written by `SimpleFit.Gyms` in the same
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
          | :primary_location_set
          | :setup_completed
          | :draft_discarded
          | :first_run_completed
          | :first_run_dismissed
          | :staff_invited
          | :staff_invitation_cancelled
          | :staff_invitation_accepted
          | :staff_invitation_declined
          | :staff_role_changed
          | :member_join_requested
          | :member_join_approved
          | :member_join_auto_approved
          | :member_join_rejected
          | :member_join_cancelled
          | :member_ended
          | :member_invited
          | :member_invitation_cancelled
          | :member_invitation_accepted
          | :member_invitation_declined
          | :join_code_rotated
          | :join_code_disabled
          | :member_auto_approval_changed
          | :venue_created
          | :venue_updated
          | :venue_deactivated
          | :class_template_created
          | :class_template_updated
          | :class_template_archived
          | :class_series_created
          | :class_series_updated
          | :class_series_cancelled
          | :class_occurrence_created
          | :class_occurrence_rescheduled
          | :class_occurrence_cancelled
          | :class_instructor_changed
          | :class_capacity_changed
          | :class_instructor_released
          | :class_booking_created
          | :class_booking_cancelled
          | :class_bookings_released
          | :class_check_in_recorded

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          actor_user_id: Ecto.UUID.t() | nil,
          event_type: event_type() | nil,
          staff_membership_id: Ecto.UUID.t() | nil,
          staff_invitation_id: Ecto.UUID.t() | nil,
          gym_member_id: Ecto.UUID.t() | nil,
          member_invitation_id: Ecto.UUID.t() | nil,
          enabled: boolean() | nil,
          venue_id: Ecto.UUID.t() | nil,
          class_template_id: Ecto.UUID.t() | nil,
          class_series_id: Ecto.UUID.t() | nil,
          class_occurrence_id: Ecto.UUID.t() | nil,
          occurrence_count: non_neg_integer() | nil,
          class_booking_id: Ecto.UUID.t() | nil,
          booking_count: non_neg_integer() | nil,
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
        :staff_membership_ended,
        :primary_location_set,
        :setup_completed,
        :draft_discarded,
        :first_run_completed,
        :first_run_dismissed,
        :staff_invited,
        :staff_invitation_cancelled,
        :staff_invitation_accepted,
        :staff_invitation_declined,
        :staff_role_changed,
        :member_join_requested,
        :member_join_approved,
        :member_join_auto_approved,
        :member_join_rejected,
        :member_join_cancelled,
        :member_ended,
        :member_invited,
        :member_invitation_cancelled,
        :member_invitation_accepted,
        :member_invitation_declined,
        :join_code_rotated,
        :join_code_disabled,
        :member_auto_approval_changed,
        :venue_created,
        :venue_updated,
        :venue_deactivated,
        :class_template_created,
        :class_template_updated,
        :class_template_archived,
        :class_series_created,
        :class_series_updated,
        :class_series_cancelled,
        :class_occurrence_created,
        :class_occurrence_rescheduled,
        :class_occurrence_cancelled,
        :class_instructor_changed,
        :class_capacity_changed,
        :class_instructor_released,
        :class_booking_created,
        :class_booking_cancelled,
        :class_bookings_released,
        :class_check_in_recorded
      ]

    field :staff_membership_id, :binary_id
    field :staff_invitation_id, :binary_id
    field :gym_member_id, :binary_id
    field :member_invitation_id, :binary_id
    field :enabled, :boolean
    field :venue_id, :binary_id
    field :class_template_id, :binary_id
    field :class_series_id, :binary_id
    field :class_occurrence_id, :binary_id
    field :occurrence_count, :integer
    field :class_booking_id, :binary_id
    field :booking_count, :integer
    field :from_role, Ecto.Enum, values: StaffMembership.roles()
    field :to_role, Ecto.Enum, values: StaffMembership.roles()

    field :reason, Ecto.Enum,
      values: [:left, :removed, :transferred, :account_deleted, :gym_closed]

    field :occurred_at, :utc_datetime_usec
  end
end
