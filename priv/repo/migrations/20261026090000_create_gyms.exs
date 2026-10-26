defmodule SimpleFit.Repo.Migrations.CreateGyms do
  use Ecto.Migration

  # SF-83: the Gym tenant, its locations, staff (workspace) memberships and
  # audit events (ADR 0026; SF-82 decisions D-G01–D-G05, D-G13, D-G18, D-G20,
  # D-G25, D-G26).
  #
  # Ownership has one source of truth: the gym's single active staff
  # membership with role `owner`. There is no `gyms.owner_user_id`. The
  # database guarantees "exactly one active owner per gym" at every commit:
  # a partial unique index forbids a second active owner immediately, and a
  # deferred constraint trigger rejects any transaction that leaves a gym
  # without one.
  #
  # Deleting a user never deletes a gym or another user's rows: memberships
  # keep their history with `user_id` set to NULL, which is only allowed for
  # ended memberships, so a user with an active membership (an owner in
  # particular) cannot be deleted until the account-deletion workflow has
  # released it (D-G26).
  def change do
    create table(:gyms) do
      add :name, :text, null: false
      add :gym_type, :text, null: false
      add :setup_status, :text, null: false
      # Audit and idempotency only: ownership lives in gym_staff_memberships.
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      # One key per creator, chosen by the client per create and repeated on
      # a retry (D-G05).
      add :client_request_id, :binary_id, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:gyms, :name_length,
             check: "char_length(name) BETWEEN 1 AND 80 AND name = btrim(name)"
           )

    create constraint(:gyms, :gym_type_values,
             check:
               "gym_type IN ('boxing_gym', 'boxing_club', 'amateur_club', 'professional_team', " <>
                 "'combat_sports_gym', 'fitness_boxing_studio')"
           )

    create constraint(:gyms, :setup_status_values,
             check: "setup_status IN ('draft', 'completed')"
           )

    create unique_index(:gyms, [:created_by_user_id, :client_request_id],
             name: :gyms_creator_request_index
           )

    # One open draft per creator (D-G25): a second create resumes it.
    create unique_index(:gyms, [:created_by_user_id],
             where: "setup_status = 'draft'",
             name: :gyms_one_open_draft_index
           )

    create table(:gym_locations) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :country_code, :text, null: false
      add :city, :text, null: false
      # Free text: no geocoding, map or tracking (OG2).
      add :address_line, :text, null: false
      add :entrance_note, :text
      add :is_primary, :boolean, null: false
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gym_locations, [:gym_id])

    create unique_index(:gym_locations, [:gym_id],
             where: "is_primary AND archived_at IS NULL",
             name: :gym_locations_one_primary_index
           )

    create constraint(:gym_locations, :name_length, check: "char_length(name) BETWEEN 1 AND 80")
    create constraint(:gym_locations, :country_code_format, check: "country_code ~ '^[A-Z]{2}$'")
    create constraint(:gym_locations, :city_length, check: "char_length(city) BETWEEN 1 AND 80")

    create constraint(:gym_locations, :address_line_length,
             check: "char_length(address_line) BETWEEN 1 AND 200"
           )

    create constraint(:gym_locations, :entrance_note_length,
             check: "entrance_note IS NULL OR char_length(entrance_note) BETWEEN 1 AND 200"
           )

    create table(:gym_staff_memberships) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :role, :text, null: false
      add :status, :text, null: false
      add :ended_at, :utc_datetime_usec
      add :ended_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:gym_staff_memberships, :role_values,
             check: "role IN ('owner', 'manager', 'coach', 'front_desk')"
           )

    create constraint(:gym_staff_memberships, :status_values,
             check: "status IN ('active', 'ended')"
           )

    create constraint(:gym_staff_memberships, :lifecycle,
             check: """
             (status = 'active' AND ended_at IS NULL AND ended_reason IS NULL)
             OR
             (status = 'ended' AND ended_at IS NOT NULL AND ended_reason IN
               ('left', 'removed', 'transferred', 'account_deleted', 'gym_closed'))
             """
           )

    # Only an ended membership may outlive its user (history after deletion).
    create constraint(:gym_staff_memberships, :user_present_while_active,
             check: "status = 'ended' OR user_id IS NOT NULL"
           )

    create unique_index(:gym_staff_memberships, [:gym_id, :user_id],
             where: "status = 'active'",
             name: :gym_staff_one_active_membership_index
           )

    create unique_index(:gym_staff_memberships, [:gym_id],
             where: "role = 'owner' AND status = 'active'",
             name: :gym_staff_one_active_owner_index
           )

    # The viewer's workspaces, newest first (keyset on inserted_at, id).
    create index(:gym_staff_memberships, [:user_id, :inserted_at, :id],
             where: "status = 'active'",
             name: :gym_staff_active_by_user_index
           )

    create table(:gym_audit_events) do
      # No foreign keys: an event outlives the rows it names (as legal
      # evidence, ADR 0022). Retention waits for an approved policy.
      add :gym_id, :binary_id, null: false
      add :actor_user_id, :binary_id
      add :event_type, :text, null: false
      add :staff_membership_id, :binary_id
      add :from_role, :text
      add :to_role, :text
      add :reason, :text
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:gym_audit_events, [:gym_id, :occurred_at, :id])

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', " <>
                 "'ownership_transferred', 'staff_membership_ended')"
           )

    create constraint(:gym_audit_events, :role_values,
             check:
               "(from_role IS NULL OR from_role IN ('owner', 'manager', 'coach', 'front_desk')) AND " <>
                 "(to_role IS NULL OR to_role IN ('owner', 'manager', 'coach', 'front_desk'))"
           )

    create constraint(:gym_audit_events, :reason_values,
             check:
               "reason IS NULL OR reason IN ('left', 'removed', 'transferred', 'account_deleted', 'gym_closed')"
           )

    # -- Triggers ---------------------------------------------------------------

    # Exactly one active owner per existing gym, checked when the transaction
    # commits (so a transfer may end one owner row before promoting another).
    execute(
      """
      CREATE FUNCTION gyms_check_single_active_owner() RETURNS trigger AS $$
      DECLARE
        target uuid;
        owners integer;
      BEGIN
        IF TG_TABLE_NAME = 'gyms' THEN
          target := NEW.id;
        ELSIF TG_OP = 'DELETE' THEN
          target := OLD.gym_id;
        ELSE
          target := NEW.gym_id;
        END IF;

        -- A deleted gym takes its memberships with it.
        IF NOT EXISTS (SELECT 1 FROM gyms WHERE id = target) THEN
          RETURN NULL;
        END IF;

        SELECT count(*) INTO owners FROM gym_staff_memberships
         WHERE gym_id = target AND role = 'owner' AND status = 'active';

        IF owners <> 1 THEN
          RAISE EXCEPTION 'a gym must have exactly one active owner'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gyms_single_active_owner';
        END IF;

        RETURN NULL;
      END
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION gyms_check_single_active_owner()"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER gyms_single_active_owner
      AFTER INSERT ON gyms
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION gyms_check_single_active_owner()
      """,
      "DROP TRIGGER gyms_single_active_owner ON gyms"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER gym_staff_single_active_owner
      AFTER INSERT OR UPDATE OR DELETE ON gym_staff_memberships
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION gyms_check_single_active_owner()
      """,
      "DROP TRIGGER gym_staff_single_active_owner ON gym_staff_memberships"
    )

    # A gym keeps its idempotency key and creator (the creator only becomes
    # NULL when the user is deleted), and a completed setup never returns to
    # draft.
    execute(
      """
      CREATE FUNCTION gyms_guard_update() RETURNS trigger AS $$
      BEGIN
        IF NEW.client_request_id IS DISTINCT FROM OLD.client_request_id THEN
          RAISE EXCEPTION 'gyms.client_request_id is immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gyms_immutable_fields';
        END IF;
        IF NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id
           AND NEW.created_by_user_id IS NOT NULL THEN
          RAISE EXCEPTION 'gyms.created_by_user_id is immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gyms_immutable_fields';
        END IF;
        IF OLD.setup_status = 'completed' AND NEW.setup_status <> 'completed' THEN
          RAISE EXCEPTION 'a completed gym setup is final'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gyms_setup_monotonic';
        END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION gyms_guard_update()"
    )

    execute(
      """
      CREATE TRIGGER gyms_guard_update
      BEFORE UPDATE ON gyms
      FOR EACH ROW EXECUTE FUNCTION gyms_guard_update()
      """,
      "DROP TRIGGER gyms_guard_update ON gyms"
    )

    # A membership never moves to another gym or user (only user deletion may
    # set user_id to NULL), and an ended membership is final.
    execute(
      """
      CREATE FUNCTION gym_staff_guard_update() RETURNS trigger AS $$
      BEGIN
        IF NEW.gym_id <> OLD.gym_id THEN
          RAISE EXCEPTION 'gym_staff_memberships.gym_id is immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_staff_immutable_fields';
        END IF;
        IF NEW.user_id IS DISTINCT FROM OLD.user_id AND NEW.user_id IS NOT NULL THEN
          RAISE EXCEPTION 'gym_staff_memberships.user_id is immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_staff_immutable_fields';
        END IF;
        IF OLD.status = 'ended' AND (
             NEW.status <> OLD.status OR NEW.role <> OLD.role OR
             NEW.ended_at IS DISTINCT FROM OLD.ended_at OR
             NEW.ended_reason IS DISTINCT FROM OLD.ended_reason) THEN
          RAISE EXCEPTION 'an ended gym staff membership is final'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_staff_ended_final';
        END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION gym_staff_guard_update()"
    )

    execute(
      """
      CREATE TRIGGER gym_staff_guard_update
      BEFORE UPDATE ON gym_staff_memberships
      FOR EACH ROW EXECUTE FUNCTION gym_staff_guard_update()
      """,
      "DROP TRIGGER gym_staff_guard_update ON gym_staff_memberships"
    )

    # Audit events are append-only.
    execute(
      """
      CREATE FUNCTION gym_audit_events_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'gym audit events are append-only'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_audit_events_append_only';
      END
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION gym_audit_events_append_only()"
    )

    execute(
      """
      CREATE TRIGGER gym_audit_events_append_only
      BEFORE UPDATE ON gym_audit_events
      FOR EACH ROW EXECUTE FUNCTION gym_audit_events_append_only()
      """,
      "DROP TRIGGER gym_audit_events_append_only ON gym_audit_events"
    )
  end
end
