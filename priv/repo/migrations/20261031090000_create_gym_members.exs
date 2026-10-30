defmodule SimpleFit.Repo.Migrations.CreateGymMembers do
  use Ecto.Migration

  # SF-95: gym members (participants), their enrollment and member
  # invitations (ADR 0026, D-G07, D-G08, D-G22; SF-82 01 §4.5).
  #
  # A gym membership is a user's participation in one gym. It is independent
  # of staff memberships (a staff member may also be a member: another row,
  # another table), of Fighter and Coach profiles, and of Coach–Fighter
  # relationships; no column here points at any of them.
  #
  # Lifecycle: `requested` (a join-code request) -> `active` (approved,
  # auto-approved or accepted from an invitation) | `rejected` (by staff) |
  # `cancelled` (by the requester); `active` -> `ended` (left or removed).
  # `ended`, `rejected` and `cancelled` are final: re-enrolling creates a new
  # row, so the history is kept. Rows are never deleted.
  def up do
    create table(:gym_members) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      # An ended, rejected or cancelled row keeps its history when its user is
      # deleted (`user_id` becomes NULL); a requested or active one blocks the
      # deletion (`user_present`).
      add :user_id, references(:users, on_delete: :nilify_all)
      add :status, :text, null: false
      add :joined_via, :text, null: false
      # Activated by the gym's explicit auto-approval setting (D-G08), not by
      # a staff member.
      add :auto_approved, :boolean, null: false, default: false
      add :requested_at, :utc_datetime_usec
      add :activated_at, :utc_datetime_usec
      # When a request was rejected or cancelled.
      add :responded_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :ended_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    # The target of the invitations' composite foreign key.
    create unique_index(:gym_members, [:gym_id, :id], name: :gym_members_gym_id_id_index)

    # At most one requested-or-active membership per gym and user; any number
    # of final ones (re-enrollment).
    create unique_index(:gym_members, [:gym_id, :user_id],
             where: "status IN ('requested', 'active')",
             name: :gym_members_current_index
           )

    # The roster (oldest first), the join requests, and the user's own list.
    create index(:gym_members, [:gym_id, :status, :inserted_at, :id],
             name: :gym_members_roster_index
           )

    create index(:gym_members, [:user_id, "inserted_at DESC", "id DESC"],
             name: :gym_members_user_index
           )

    create constraint(:gym_members, :status_values,
             check: "status IN ('requested', 'active', 'ended', 'rejected', 'cancelled')"
           )

    create constraint(:gym_members, :joined_via_values,
             check: "joined_via IN ('join_code', 'invitation')"
           )

    create constraint(:gym_members, :ended_reason_values,
             check:
               "ended_reason IS NULL OR ended_reason IN ('left', 'removed', 'account_deleted', 'gym_closed')"
           )

    create constraint(:gym_members, :user_present,
             check: "status IN ('ended', 'rejected', 'cancelled') OR user_id IS NOT NULL"
           )

    # Only a join-code request can be auto-approved; an invitation is the
    # gym's own decision.
    create constraint(:gym_members, :auto_approved_shape,
             check: "NOT auto_approved OR joined_via = 'join_code'"
           )

    # Each status has exactly its own timestamps.
    create constraint(:gym_members, :lifecycle,
             check: """
             (joined_via <> 'join_code' OR requested_at IS NOT NULL) AND
             (joined_via <> 'invitation' OR requested_at IS NULL) AND
             (
               (status = 'requested' AND activated_at IS NULL AND responded_at IS NULL AND
                ended_at IS NULL AND ended_reason IS NULL)
               OR
               (status = 'active' AND activated_at IS NOT NULL AND responded_at IS NULL AND
                ended_at IS NULL AND ended_reason IS NULL)
               OR
               (status = 'ended' AND activated_at IS NOT NULL AND responded_at IS NULL AND
                ended_at IS NOT NULL AND ended_reason IS NOT NULL)
               OR
               (status IN ('rejected', 'cancelled') AND joined_via = 'join_code' AND
                activated_at IS NULL AND responded_at IS NOT NULL AND
                ended_at IS NULL AND ended_reason IS NULL)
             )
             """
           )

    # Members exist only at a completed gym, and start requested or active
    # (an active row is born only from an invitation or an auto-approval).
    execute("""
    CREATE FUNCTION gym_members_guard_insert() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM gyms WHERE id = NEW.gym_id AND setup_status = 'completed'
      ) THEN
        RAISE EXCEPTION 'gym members need a completed gym'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_members_completed_gym';
      END IF;
      IF NEW.status NOT IN ('requested', 'active') OR
         (NEW.status = 'active' AND NEW.joined_via = 'join_code' AND NOT NEW.auto_approved) THEN
        RAISE EXCEPTION 'a gym membership starts requested, or active from an invitation or auto-approval'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_members_initial_status';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_members_guard_insert
    BEFORE INSERT ON gym_members
    FOR EACH ROW EXECUTE FUNCTION gym_members_guard_insert()
    """)

    # Allowed moves: requested -> active | rejected | cancelled; active ->
    # ended. A final row never changes again, except that its user may be
    # removed (account deletion). Gym, user, origin and creation never change.
    execute("""
    CREATE FUNCTION gym_members_guard_update() RETURNS trigger AS $$
    BEGIN
      IF NEW.user_id IS NOT NULL AND NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'gym_members.user_id is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_members_identity';
      END IF;

      IF NEW.gym_id IS DISTINCT FROM OLD.gym_id OR
         NEW.joined_via IS DISTINCT FROM OLD.joined_via OR
         NEW.auto_approved IS DISTINCT FROM OLD.auto_approved OR
         NEW.requested_at IS DISTINCT FROM OLD.requested_at OR
         NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
        RAISE EXCEPTION 'a gym membership keeps its gym, origin and creation'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_members_identity';
      END IF;

      IF OLD.status IN ('ended', 'rejected', 'cancelled') THEN
        IF (to_jsonb(NEW) - 'user_id' - 'updated_at') IS DISTINCT FROM
           (to_jsonb(OLD) - 'user_id' - 'updated_at') THEN
          RAISE EXCEPTION 'a final gym membership is immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_members_final_immutable';
        END IF;
        RETURN NEW;
      END IF;

      IF NOT (
        NEW.status = OLD.status OR
        (OLD.status = 'requested' AND NEW.status IN ('active', 'rejected', 'cancelled')) OR
        (OLD.status = 'active' AND NEW.status = 'ended')
      ) THEN
        RAISE EXCEPTION 'gym membership transition % -> % is not allowed', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_members_transition';
      END IF;

      IF OLD.status = 'active' AND NEW.activated_at IS DISTINCT FROM OLD.activated_at THEN
        RAISE EXCEPTION 'an active gym membership keeps its activation'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_members_identity';
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_members_guard_update
    BEFORE UPDATE ON gym_members
    FOR EACH ROW EXECUTE FUNCTION gym_members_guard_update()
    """)

    # No physical deletion (SF-95): a membership ends, is rejected or is
    # cancelled, and its row stays. Only a maintenance session that sets
    # `simple_fit.allow_gym_member_purge` (test cleanup; a future, approved
    # retention job) may delete rows.
    execute("""
    CREATE FUNCTION gym_members_guard_delete() RETURNS trigger AS $$
    BEGIN
      IF coalesce(current_setting('simple_fit.allow_gym_member_purge', true), '') <> 'on' THEN
        RAISE EXCEPTION 'gym memberships are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_members_no_delete';
      END IF;
      RETURN OLD;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_members_guard_delete
    BEFORE DELETE ON gym_members
    FOR EACH ROW EXECUTE FUNCTION gym_members_guard_delete()
    """)

    # -- Member invitations (E07) ------------------------------------------------

    # As staff invitations (SF-93), without a role: the token only as its
    # SHA-256, the recipient only as an HMAC digest plus an encrypted copy.
    create table(:gym_member_invitations) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :invited_by_staff_membership_id, :binary_id, null: false
      add :token_hash, :binary, null: false
      add :recipient_digest, :binary, null: false
      add :recipient_sealed, :text, null: false
      add :status, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :send_count, :integer, null: false, default: 1
      add :last_sent_at, :utc_datetime_usec, null: false
      add :responded_at, :utc_datetime_usec
      # The membership an acceptance activated.
      add :gym_member_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    ALTER TABLE gym_member_invitations
      ADD CONSTRAINT gym_member_invitations_inviter_fkey
      FOREIGN KEY (gym_id, invited_by_staff_membership_id)
      REFERENCES gym_staff_memberships (gym_id, id),
      ADD CONSTRAINT gym_member_invitations_member_fkey
      FOREIGN KEY (gym_id, gym_member_id)
      REFERENCES gym_members (gym_id, id)
    """)

    create unique_index(:gym_member_invitations, [:token_hash])

    create unique_index(:gym_member_invitations, [:gym_id, :recipient_digest],
             where: "status = 'pending'",
             name: :gym_member_invitations_pending_recipient_index
           )

    create unique_index(:gym_member_invitations, [:gym_member_id],
             where: "gym_member_id IS NOT NULL",
             name: :gym_member_invitations_member_index
           )

    create index(:gym_member_invitations, [:gym_id, "inserted_at DESC", "id DESC"],
             name: :gym_member_invitations_gym_index
           )

    create index(:gym_member_invitations, [:recipient_digest, "inserted_at DESC", "id DESC"],
             name: :gym_member_invitations_recipient_index
           )

    create index(:gym_member_invitations, [:invited_by_staff_membership_id],
             where: "status = 'pending'",
             name: :gym_member_invitations_pending_inviter_index
           )

    create constraint(:gym_member_invitations, :status_values,
             check: "status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')"
           )

    create constraint(:gym_member_invitations, :digest_sizes,
             check: "octet_length(token_hash) = 32 AND octet_length(recipient_digest) = 32"
           )

    create constraint(:gym_member_invitations, :send_count_range, check: "send_count >= 1")

    create constraint(:gym_member_invitations, :outcome_shape,
             check: """
             (status IN ('pending', 'expired') AND responded_at IS NULL AND gym_member_id IS NULL)
             OR
             (status = 'accepted' AND responded_at IS NOT NULL AND gym_member_id IS NOT NULL)
             OR
             (status IN ('declined', 'cancelled') AND responded_at IS NOT NULL AND
              gym_member_id IS NULL)
             """
           )

    execute("""
    CREATE FUNCTION gym_member_invitations_guard_insert() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM gyms WHERE id = NEW.gym_id AND setup_status = 'completed'
      ) THEN
        RAISE EXCEPTION 'member invitations need a completed gym'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_invitations_completed_gym';
      END IF;
      IF NEW.status <> 'pending' THEN
        RAISE EXCEPTION 'a member invitation starts pending'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_invitations_starts_pending';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_member_invitations_guard_insert
    BEFORE INSERT ON gym_member_invitations
    FOR EACH ROW EXECUTE FUNCTION gym_member_invitations_guard_insert()
    """)

    execute("""
    CREATE FUNCTION gym_member_invitations_guard_update() RETURNS trigger AS $$
    BEGIN
      IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'a resolved member invitation is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_invitations_resolved_immutable';
      END IF;

      IF NEW.gym_id IS DISTINCT FROM OLD.gym_id OR
         NEW.recipient_digest IS DISTINCT FROM OLD.recipient_digest OR
         NEW.recipient_sealed IS DISTINCT FROM OLD.recipient_sealed OR
         NEW.invited_by_staff_membership_id IS DISTINCT FROM OLD.invited_by_staff_membership_id OR
         NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
        RAISE EXCEPTION 'a member invitation keeps its gym, recipient and inviter'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_invitations_identity';
      END IF;

      IF NEW.status = 'accepted' AND NOT EXISTS (
        SELECT 1 FROM gym_members m
         WHERE m.id = NEW.gym_member_id AND m.gym_id = NEW.gym_id AND m.status = 'active'
      ) THEN
        RAISE EXCEPTION 'an accepted member invitation names an active membership'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_invitations_accepted_member';
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_member_invitations_guard_update
    BEFORE UPDATE ON gym_member_invitations
    FOR EACH ROW EXECUTE FUNCTION gym_member_invitations_guard_update()
    """)

    # -- Enrollment settings ------------------------------------------------------

    # One row per gym, created by its first setting change. No row: no join
    # code and no auto-approval (D-G08: off unless explicitly enabled). The
    # code is stored as an HMAC digest (the lookup key) and an encrypted copy
    # (shown to the gym's staff); no code means joining by code is disabled.
    create table(:gym_enrollment_settings, primary_key: false) do
      add :gym_id, references(:gyms, on_delete: :delete_all), primary_key: true
      add :join_code_digest, :binary
      add :join_code_sealed, :text
      add :join_code_rotated_at, :utc_datetime_usec
      add :auto_approve, :boolean, null: false, default: false
      add :auto_approve_changed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_enrollment_settings, [:join_code_digest],
             where: "join_code_digest IS NOT NULL",
             name: :gym_enrollment_settings_join_code_index
           )

    create constraint(:gym_enrollment_settings, :join_code_shape,
             check: """
             (join_code_digest IS NULL AND join_code_sealed IS NULL) OR
             (octet_length(join_code_digest) = 32 AND join_code_sealed IS NOT NULL AND
              join_code_rotated_at IS NOT NULL)
             """
           )

    execute("""
    CREATE FUNCTION gym_enrollment_settings_guard_insert() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM gyms WHERE id = NEW.gym_id AND setup_status = 'completed'
      ) THEN
        RAISE EXCEPTION 'enrollment settings need a completed gym'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_enrollment_settings_completed_gym';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_enrollment_settings_guard_insert
    BEFORE INSERT ON gym_enrollment_settings
    FOR EACH ROW EXECUTE FUNCTION gym_enrollment_settings_guard_insert()
    """)

    # -- Audit ----------------------------------------------------------------------

    alter table(:gym_audit_events) do
      add :gym_member_id, :binary_id
      add :member_invitation_id, :binary_id
      # The new value of a boolean setting (auto-approval).
      add :enabled, :boolean
    end

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', 'ownership_transferred', " <>
                 "'staff_membership_ended', 'primary_location_set', 'setup_completed', 'draft_discarded', " <>
                 "'first_run_completed', 'first_run_dismissed', 'staff_invited', " <>
                 "'staff_invitation_cancelled', 'staff_invitation_accepted', " <>
                 "'staff_invitation_declined', 'staff_role_changed', " <>
                 "'member_join_requested', 'member_join_approved', 'member_join_auto_approved', " <>
                 "'member_join_rejected', 'member_join_cancelled', 'member_ended', " <>
                 "'member_invited', 'member_invitation_cancelled', 'member_invitation_accepted', " <>
                 "'member_invitation_declined', 'join_code_rotated', 'join_code_disabled', " <>
                 "'member_auto_approval_changed')"
           )
  end

  def down do
    execute("""
    DELETE FROM gym_audit_events WHERE event_type IN ('member_join_requested',
      'member_join_approved', 'member_join_auto_approved', 'member_join_rejected',
      'member_join_cancelled', 'member_ended', 'member_invited', 'member_invitation_cancelled',
      'member_invitation_accepted', 'member_invitation_declined', 'join_code_rotated',
      'join_code_disabled', 'member_auto_approval_changed')
    """)

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', 'ownership_transferred', " <>
                 "'staff_membership_ended', 'primary_location_set', 'setup_completed', 'draft_discarded', " <>
                 "'first_run_completed', 'first_run_dismissed', 'staff_invited', " <>
                 "'staff_invitation_cancelled', 'staff_invitation_accepted', " <>
                 "'staff_invitation_declined', 'staff_role_changed')"
           )

    alter table(:gym_audit_events) do
      remove :gym_member_id
      remove :member_invitation_id
      remove :enabled
    end

    execute("DROP TRIGGER gym_enrollment_settings_guard_insert ON gym_enrollment_settings")
    execute("DROP FUNCTION gym_enrollment_settings_guard_insert()")
    drop table(:gym_enrollment_settings)

    execute("DROP TRIGGER gym_member_invitations_guard_update ON gym_member_invitations")
    execute("DROP FUNCTION gym_member_invitations_guard_update()")
    execute("DROP TRIGGER gym_member_invitations_guard_insert ON gym_member_invitations")
    execute("DROP FUNCTION gym_member_invitations_guard_insert()")
    drop table(:gym_member_invitations)

    # Rolling back drops every membership with its table (DROP TABLE fires no
    # row trigger).
    execute("DROP TRIGGER gym_members_guard_delete ON gym_members")
    execute("DROP FUNCTION gym_members_guard_delete()")
    execute("DROP TRIGGER gym_members_guard_update ON gym_members")
    execute("DROP FUNCTION gym_members_guard_update()")
    execute("DROP TRIGGER gym_members_guard_insert ON gym_members")
    execute("DROP FUNCTION gym_members_guard_insert()")
    drop table(:gym_members)
  end
end
