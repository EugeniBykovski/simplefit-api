defmodule SimpleFit.Repo.Migrations.CreateGymClassBookings do
  @moduledoc """
  SF-99: class bookings and check-ins (ADR 0026 amendment SF-99; SF-82 01
  §4.7–4.8, 02 §4, 08 T7).

  * `gym_class_bookings` - a gym member's place in one class occurrence:
    `confirmed` (it holds a seat) or `cancelled` (history; it holds none).
    Composite foreign keys keep the occurrence and the member in the
    booking's gym. At most one confirmed booking per member and class (a
    partial unique index); a `client_request_id` names one logical booking
    per gym, for ever (a replay after a cancellation returns the cancelled
    booking, never a new one).
  * `gym_class_check_ins` - an attendance event: staff recorded that the
    member of a confirmed booking came. One per booking (a repeat is the
    same event), never changed or deleted.

  The capacity invariant (`confirmed bookings <= occurrence capacity`) is
  enforced by the database as well as by the application: a booking that
  confirms locks its occurrence row (`FOR UPDATE`) and counts the confirmed
  rows; an occurrence update holds that row too, and may not lower the
  capacity below its confirmed bookings nor cancel a class that still has
  any (the application releases them first, in the same transaction).
  There is no counter column that could drift.
  """

  use Ecto.Migration

  @previous ~w(gym_created staff_membership_created ownership_transferred
               staff_membership_ended primary_location_set setup_completed draft_discarded
               first_run_completed first_run_dismissed staff_invited
               staff_invitation_cancelled staff_invitation_accepted
               staff_invitation_declined staff_role_changed
               member_join_requested member_join_approved member_join_auto_approved
               member_join_rejected member_join_cancelled member_ended
               member_invited member_invitation_cancelled member_invitation_accepted
               member_invitation_declined join_code_rotated join_code_disabled
               member_auto_approval_changed
               venue_created venue_updated venue_deactivated
               class_template_created class_template_updated class_template_archived
               class_series_created class_series_updated class_series_cancelled
               class_occurrence_created class_occurrence_rescheduled class_occurrence_cancelled
               class_instructor_changed class_capacity_changed class_instructor_released)

  @new ~w(class_booking_created class_booking_cancelled class_bookings_released
          class_check_in_recorded)

  def up do
    create unique_index(:gym_class_occurrences, [:gym_id, :id],
             name: :gym_class_occurrences_gym_id_id_index
           )

    # -- Bookings ----------------------------------------------------------------------

    create table(:gym_class_bookings) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :occurrence_id,
          references(:gym_class_occurrences,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :gym_member_id,
          references(:gym_members, with: [gym_id: :gym_id], match: :full, on_delete: :nothing),
          null: false

      add :status, :text, null: false, default: "confirmed"
      # Who made it: the member themselves or a staff member for them.
      add :booked_via, :text, null: false
      add :booked_by_user_id, references(:users, on_delete: :nilify_all)
      add :client_request_id, :binary_id, null: false
      add :confirmed_at, :utc_datetime_usec, null: false
      add :cancelled_at, :utc_datetime_usec
      add :cancel_reason, :text
      add :cancelled_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_class_bookings, [:gym_id, :id],
             name: :gym_class_bookings_gym_id_id_index
           )

    create unique_index(:gym_class_bookings, [:id, :occurrence_id, :gym_member_id],
             name: :gym_class_bookings_identity_index
           )

    create unique_index(:gym_class_bookings, [:gym_id, :client_request_id],
             name: :gym_class_bookings_request_index
           )

    create unique_index(:gym_class_bookings, [:occurrence_id, :gym_member_id],
             where: "status = 'confirmed'",
             name: :gym_class_bookings_current_index
           )

    create index(:gym_class_bookings, [:occurrence_id, :confirmed_at, :id])
    create index(:gym_class_bookings, [:gym_member_id, :inserted_at, :id])

    create constraint(:gym_class_bookings, :status_values,
             check: "status IN ('confirmed', 'cancelled')"
           )

    create constraint(:gym_class_bookings, :booked_via_values,
             check: "booked_via IN ('member', 'staff')"
           )

    create constraint(:gym_class_bookings, :cancellation,
             check:
               "(status = 'cancelled') = (cancelled_at IS NOT NULL) AND " <>
                 "(status = 'cancelled') = (cancel_reason IS NOT NULL) AND " <>
                 "(cancel_reason IS NULL OR cancel_reason IN " <>
                 "('member_cancelled', 'staff_cancelled', 'occurrence_cancelled', 'membership_ended'))"
           )

    # -- Check-ins ---------------------------------------------------------------------

    create table(:gym_class_check_ins) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :occurrence_id,
          references(:gym_class_occurrences,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :booking_id,
          references(:gym_class_bookings,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :gym_member_id,
          references(:gym_members, with: [gym_id: :gym_id], match: :full, on_delete: :nothing),
          null: false

      add :recorded_by_user_id, references(:users, on_delete: :nilify_all)

      add :recorded_by_staff_membership_id,
          references(:gym_staff_memberships,
            with: [gym_id: :gym_id],
            match: :simple,
            on_delete: :nothing
          )

      # Only manual check-ins exist (no QR pass, NFC or location: FUTURE).
      add :method, :text, null: false, default: "manual"
      add :checked_in_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    # The check-in is of exactly that booking's class and member.
    execute("""
    ALTER TABLE gym_class_check_ins ADD CONSTRAINT gym_class_check_ins_booking_identity_fkey
      FOREIGN KEY (booking_id, occurrence_id, gym_member_id)
      REFERENCES gym_class_bookings (id, occurrence_id, gym_member_id)
    """)

    create unique_index(:gym_class_check_ins, [:booking_id],
             name: :gym_class_check_ins_booking_index
           )

    create index(:gym_class_check_ins, [:occurrence_id])
    create index(:gym_class_check_ins, [:gym_id, :checked_in_at])

    create constraint(:gym_class_check_ins, :method_values, check: "method IN ('manual')")

    # -- Guards ------------------------------------------------------------------------

    # Bookings: born confirmed, in a scheduled class, for an active member,
    # within the class's capacity (counted under the occurrence row lock);
    # confirmed -> cancelled is the only transition, and a cancelled booking
    # is final; identity fields never change.
    execute("""
    CREATE FUNCTION gym_class_bookings_guard() RETURNS trigger AS $$
    DECLARE
      occurrence_status text;
      occurrence_capacity integer;
      confirmed integer;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'confirmed' THEN
          RAISE EXCEPTION 'a booking starts confirmed'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_bookings_transition';
        END IF;

        SELECT status, capacity INTO occurrence_status, occurrence_capacity
          FROM gym_class_occurrences
         WHERE id = NEW.occurrence_id AND gym_id = NEW.gym_id
           FOR UPDATE;

        IF occurrence_status IS DISTINCT FROM 'scheduled' THEN
          RAISE EXCEPTION 'only scheduled classes are booked'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_bookings_occurrence_scheduled';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM gym_members
                        WHERE id = NEW.gym_member_id AND gym_id = NEW.gym_id
                          AND status = 'active' FOR SHARE) THEN
          RAISE EXCEPTION 'only active members book'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_bookings_member_active';
        END IF;

        SELECT count(*) INTO confirmed FROM gym_class_bookings
         WHERE occurrence_id = NEW.occurrence_id AND status = 'confirmed';

        IF confirmed >= occurrence_capacity THEN
          RAISE EXCEPTION 'the class is full'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_bookings_capacity';
        END IF;
      ELSE
        IF NEW.gym_id <> OLD.gym_id OR NEW.occurrence_id <> OLD.occurrence_id
           OR NEW.gym_member_id <> OLD.gym_member_id
           OR NEW.client_request_id <> OLD.client_request_id
           OR NEW.booked_via <> OLD.booked_via
           OR NEW.booked_by_user_id IS DISTINCT FROM OLD.booked_by_user_id
              AND NEW.booked_by_user_id IS NOT NULL
           OR NEW.confirmed_at <> OLD.confirmed_at THEN
          RAISE EXCEPTION 'a booking keeps its class, member, request and confirmation'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_bookings_immutable';
        END IF;

        IF OLD.status = 'cancelled' AND (NEW.status <> 'cancelled'
           OR NEW.cancelled_at <> OLD.cancelled_at
           OR NEW.cancel_reason <> OLD.cancel_reason) THEN
          RAISE EXCEPTION 'a cancelled booking is final'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_bookings_transition';
        END IF;
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_class_bookings_guard BEFORE INSERT OR UPDATE ON gym_class_bookings
    FOR EACH ROW EXECUTE FUNCTION gym_class_bookings_guard()
    """)

    # Check-ins: of a confirmed booking in a scheduled class; never changed.
    execute("""
    CREATE FUNCTION gym_class_check_ins_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        -- Only a deleted recorder's id is cleared (users ON DELETE SET NULL).
        IF NEW.recorded_by_user_id IS NULL AND OLD.recorded_by_user_id IS NOT NULL
           AND (NEW.id, NEW.gym_id, NEW.occurrence_id, NEW.booking_id, NEW.gym_member_id,
                NEW.recorded_by_staff_membership_id, NEW.method, NEW.checked_in_at)
               IS NOT DISTINCT FROM
               (OLD.id, OLD.gym_id, OLD.occurrence_id, OLD.booking_id, OLD.gym_member_id,
                OLD.recorded_by_staff_membership_id, OLD.method, OLD.checked_in_at) THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'a check-in is never changed'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_check_ins_immutable';
      END IF;

      IF NOT EXISTS (SELECT 1 FROM gym_class_bookings
                      WHERE id = NEW.booking_id AND status = 'confirmed' FOR SHARE) THEN
        RAISE EXCEPTION 'only confirmed bookings are checked in'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_check_ins_booking_confirmed';
      END IF;

      IF NOT EXISTS (SELECT 1 FROM gym_class_occurrences
                      WHERE id = NEW.occurrence_id AND status = 'scheduled' FOR SHARE) THEN
        RAISE EXCEPTION 'only scheduled classes take check-ins'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_check_ins_occurrence_scheduled';
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_class_check_ins_guard BEFORE INSERT OR UPDATE ON gym_class_check_ins
    FOR EACH ROW EXECUTE FUNCTION gym_class_check_ins_guard()
    """)

    # Occurrences with bookings: the capacity never goes below the confirmed
    # bookings, and a class is cancelled only once its bookings are released
    # (the application does both in one transaction, holding this row).
    execute("""
    CREATE FUNCTION gym_class_occurrences_bookings_guard() RETURNS trigger AS $$
    DECLARE
      confirmed integer;
    BEGIN
      IF NEW.capacity = OLD.capacity AND NEW.status = OLD.status THEN
        RETURN NEW;
      END IF;

      SELECT count(*) INTO confirmed FROM gym_class_bookings
       WHERE occurrence_id = NEW.id AND status = 'confirmed';

      IF NEW.status = 'scheduled' AND NEW.capacity < confirmed THEN
        RAISE EXCEPTION 'the capacity is below the confirmed bookings'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_occurrences_capacity_bookings';
      END IF;

      IF NEW.status = 'cancelled' AND OLD.status = 'scheduled' AND confirmed > 0 THEN
        RAISE EXCEPTION 'a class with confirmed bookings is cancelled with them'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_occurrences_cancel_bookings';
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_class_occurrences_bookings_guard
    BEFORE UPDATE OF capacity, status ON gym_class_occurrences
    FOR EACH ROW EXECUTE FUNCTION gym_class_occurrences_bookings_guard()
    """)

    # Never deleted (history), except by the SF-95 purge switch (test cleanup).
    for table <- ~w(gym_class_bookings gym_class_check_ins) do
      execute("""
      CREATE TRIGGER #{table}_guard_delete BEFORE DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION gym_schedule_guard_delete()
      """)
    end

    # -- Audit -------------------------------------------------------------------------

    alter table(:gym_audit_events) do
      add :class_booking_id, :binary_id
      # How many bookings an occurrence cancellation or a membership end released.
      add :booking_count, :integer
    end

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@previous ++ @new)})"
           )
  end

  def down do
    execute("DELETE FROM gym_audit_events WHERE event_type IN (#{quoted(@new)})")
    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@previous)})"
           )

    alter table(:gym_audit_events) do
      remove :class_booking_id
      remove :booking_count
    end

    for table <- ~w(gym_class_check_ins gym_class_bookings) do
      execute("DROP TRIGGER #{table}_guard_delete ON #{table}")
    end

    execute("DROP TRIGGER gym_class_occurrences_bookings_guard ON gym_class_occurrences")

    execute("DROP FUNCTION gym_class_occurrences_bookings_guard()")
    execute("DROP TRIGGER gym_class_check_ins_guard ON gym_class_check_ins")
    execute("DROP FUNCTION gym_class_check_ins_guard()")
    execute("DROP TRIGGER gym_class_bookings_guard ON gym_class_bookings")
    execute("DROP FUNCTION gym_class_bookings_guard()")
    drop table(:gym_class_check_ins)
    drop table(:gym_class_bookings)

    drop index(:gym_class_occurrences, [:gym_id, :id],
           name: :gym_class_occurrences_gym_id_id_index
         )
  end

  defp quoted(types), do: Enum.map_join(types, ", ", &"'#{&1}'")
end
