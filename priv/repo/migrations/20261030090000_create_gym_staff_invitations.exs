defmodule SimpleFit.Repo.Migrations.CreateGymStaffInvitations do
  use Ecto.Migration

  # SF-93: gym staff invitations, role changes and the end of staff
  # memberships (ADR 0026, D-G03, D-G04, D-G12, D-G16, D-G18, D-G22).
  #
  # An invitation grants nothing: only the recipient's explicit acceptance
  # creates a staff membership, in the transaction that consumes the
  # invitation. The token is stored only as its SHA-256 and the recipient
  # only as an HMAC digest plus an encrypted copy (as coach invitations,
  # SF-57). Composite foreign keys keep the inviter's and the accepted
  # membership inside the invitation's gym.
  def up do
    # The target of the composite foreign keys below (the primary key alone
    # cannot carry the gym).
    create unique_index(:gym_staff_memberships, [:gym_id, :id],
             name: :gym_staff_memberships_gym_id_id_index
           )

    create table(:gym_staff_invitations) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :invited_by_staff_membership_id, :binary_id, null: false
      add :token_hash, :binary, null: false
      add :recipient_digest, :binary, null: false
      add :recipient_sealed, :text, null: false
      add :role, :text, null: false
      add :status, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      # Deliveries (the first send and each resend) and the last one.
      add :send_count, :integer, null: false, default: 1
      add :last_sent_at, :utc_datetime_usec, null: false
      # When the invitation was accepted, declined or cancelled.
      add :responded_at, :utc_datetime_usec
      # The membership an acceptance created.
      add :staff_membership_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    ALTER TABLE gym_staff_invitations
      ADD CONSTRAINT gym_staff_invitations_inviter_fkey
      FOREIGN KEY (gym_id, invited_by_staff_membership_id)
      REFERENCES gym_staff_memberships (gym_id, id),
      ADD CONSTRAINT gym_staff_invitations_membership_fkey
      FOREIGN KEY (gym_id, staff_membership_id)
      REFERENCES gym_staff_memberships (gym_id, id)
    """)

    create unique_index(:gym_staff_invitations, [:token_hash])

    # One pending invitation per gym and recipient, whatever the role.
    create unique_index(:gym_staff_invitations, [:gym_id, :recipient_digest],
             where: "status = 'pending'",
             name: :gym_staff_invitations_pending_recipient_index
           )

    # One acceptance per membership.
    create unique_index(:gym_staff_invitations, [:staff_membership_id],
             where: "staff_membership_id IS NOT NULL",
             name: :gym_staff_invitations_membership_index
           )

    # The gym's list and the recipient's inbox, newest first.
    create index(:gym_staff_invitations, [:gym_id, "inserted_at DESC", "id DESC"],
             name: :gym_staff_invitations_gym_index
           )

    create index(:gym_staff_invitations, [:recipient_digest, "inserted_at DESC", "id DESC"],
             name: :gym_staff_invitations_recipient_index
           )

    create index(:gym_staff_invitations, [:invited_by_staff_membership_id],
             where: "status = 'pending'",
             name: :gym_staff_invitations_pending_inviter_index
           )

    # Never the owner: ownership moves only by transfer (D-G04).
    create constraint(:gym_staff_invitations, :role_values,
             check: "role IN ('manager', 'coach', 'front_desk')"
           )

    create constraint(:gym_staff_invitations, :status_values,
             check: "status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')"
           )

    create constraint(:gym_staff_invitations, :digest_sizes,
             check: "octet_length(token_hash) = 32 AND octet_length(recipient_digest) = 32"
           )

    create constraint(:gym_staff_invitations, :send_count_range, check: "send_count >= 1")

    # Only an acceptance names a membership; only a response has a time.
    create constraint(:gym_staff_invitations, :outcome_shape,
             check: """
             (status IN ('pending', 'expired') AND responded_at IS NULL AND
              staff_membership_id IS NULL)
             OR
             (status = 'accepted' AND responded_at IS NOT NULL AND
              staff_membership_id IS NOT NULL)
             OR
             (status IN ('declined', 'cancelled') AND responded_at IS NOT NULL AND
              staff_membership_id IS NULL)
             """
           )

    # Invitations exist only at a completed gym: a draft has no staff but its
    # owner (D-G20), and a completed setup is final.
    execute("""
    CREATE FUNCTION gym_staff_invitations_guard_insert() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM gyms WHERE id = NEW.gym_id AND setup_status = 'completed'
      ) THEN
        RAISE EXCEPTION 'staff invitations need a completed gym'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_staff_invitations_completed_gym';
      END IF;
      IF NEW.status <> 'pending' THEN
        RAISE EXCEPTION 'a staff invitation starts pending'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_staff_invitations_starts_pending';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_staff_invitations_guard_insert
    BEFORE INSERT ON gym_staff_invitations
    FOR EACH ROW EXECUTE FUNCTION gym_staff_invitations_guard_insert()
    """)

    # A resolved invitation never changes again (it is never accepted twice
    # and never reopens). A pending one keeps its gym, recipient, role,
    # inviter and creation; only its token, expiry and deliveries move (a
    # resend). An acceptance names an active membership of the invited role.
    execute("""
    CREATE FUNCTION gym_staff_invitations_guard_update() RETURNS trigger AS $$
    BEGIN
      IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'a resolved staff invitation is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_staff_invitations_resolved_immutable';
      END IF;

      IF NEW.gym_id IS DISTINCT FROM OLD.gym_id OR
         NEW.recipient_digest IS DISTINCT FROM OLD.recipient_digest OR
         NEW.recipient_sealed IS DISTINCT FROM OLD.recipient_sealed OR
         NEW.role IS DISTINCT FROM OLD.role OR
         NEW.invited_by_staff_membership_id IS DISTINCT FROM OLD.invited_by_staff_membership_id OR
         NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
        RAISE EXCEPTION 'a staff invitation keeps its gym, recipient, role and inviter'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_staff_invitations_identity';
      END IF;

      IF NEW.status = 'accepted' AND NOT EXISTS (
        SELECT 1 FROM gym_staff_memberships m
         WHERE m.id = NEW.staff_membership_id AND m.gym_id = NEW.gym_id
           AND m.status = 'active' AND m.role = NEW.role
      ) THEN
        RAISE EXCEPTION 'an accepted staff invitation names an active membership of its role'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_staff_invitations_accepted_membership';
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_staff_invitations_guard_update
    BEFORE UPDATE ON gym_staff_invitations
    FOR EACH ROW EXECUTE FUNCTION gym_staff_invitations_guard_update()
    """)

    # Audit: the invitation an event concerns, and the new event types.
    alter table(:gym_audit_events) do
      add :staff_invitation_id, :binary_id
    end

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', 'ownership_transferred', " <>
                 "'staff_membership_ended', 'primary_location_set', 'setup_completed', 'draft_discarded', " <>
                 "'first_run_completed', 'first_run_dismissed', 'staff_invited', " <>
                 "'staff_invitation_cancelled', 'staff_invitation_accepted', " <>
                 "'staff_invitation_declined', 'staff_role_changed')"
           )
  end

  def down do
    execute("""
    DELETE FROM gym_audit_events WHERE event_type IN ('staff_invited', 'staff_invitation_cancelled',
      'staff_invitation_accepted', 'staff_invitation_declined', 'staff_role_changed')
    """)

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', 'ownership_transferred', " <>
                 "'staff_membership_ended', 'primary_location_set', 'setup_completed', 'draft_discarded', " <>
                 "'first_run_completed', 'first_run_dismissed')"
           )

    alter table(:gym_audit_events) do
      remove :staff_invitation_id
    end

    execute("DROP TRIGGER gym_staff_invitations_guard_update ON gym_staff_invitations")
    execute("DROP FUNCTION gym_staff_invitations_guard_update()")
    execute("DROP TRIGGER gym_staff_invitations_guard_insert ON gym_staff_invitations")
    execute("DROP FUNCTION gym_staff_invitations_guard_insert()")
    drop table(:gym_staff_invitations)

    drop index(:gym_staff_memberships, [:gym_id, :id],
           name: :gym_staff_memberships_gym_id_id_index
         )
  end
end
