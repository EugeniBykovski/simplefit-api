defmodule SimpleFit.Repo.Migrations.CreateTrainingSessions do
  use Ecto.Migration

  # SF-62: training sessions (ADR 0023; SF-49 §8). One row is one planned
  # training a coach assigns to one fighter within one active Coach–Fighter
  # relationship: `planned`, then `completed` or `cancelled` (both terminal).
  # No gym, no group, no metrics. Rows go with their relationship (and so with
  # either user) when it is deleted (product decision 2026-10-20).
  def change do
    # The composite reference below needs a unique key on the relationship's
    # id with its two parties. Additive: the id alone is already unique.
    create unique_index(
             :coach_fighter_relationships,
             [:id, :coach_profile_id, :fighter_profile_id],
             name: :coach_fighter_relationships_parties_index
           )

    create table(:training_sessions) do
      add :coach_fighter_relationship_id, :binary_id, null: false
      add :coach_profile_id, references(:coach_profiles, on_delete: :delete_all), null: false
      add :fighter_profile_id, references(:fighter_profiles, on_delete: :delete_all), null: false

      # Idempotency of creation (SF-49 §8.2): one key per coach, chosen by the
      # client for one create request and repeated on a retry.
      add :client_request_id, :binary_id, null: false

      add :title, :text, null: false
      add :training_type, :text, null: false
      # The instant the session starts (UTC) and the IANA zone the coach
      # planned it in, used by clients to show the coach's wall time.
      add :starts_at, :utc_datetime_usec, null: false
      add :time_zone, :text, null: false
      add :duration_minutes, :integer, null: false
      add :notes, :text

      add :status, :text, null: false
      # Set by the backend only, once, by the transition that ends the plan.
      add :completed_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :cancelled_by, :text
      add :cancel_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    # The session's coach and fighter are exactly its relationship's: one
    # reference to the relationship's (id, coach, fighter) key, so a row can
    # never pair a relationship with another coach or fighter.
    execute(
      """
      ALTER TABLE training_sessions
        ADD CONSTRAINT training_sessions_relationship_parties_fkey
        FOREIGN KEY (coach_fighter_relationship_id, coach_profile_id, fighter_profile_id)
        REFERENCES coach_fighter_relationships (id, coach_profile_id, fighter_profile_id)
        ON DELETE CASCADE
      """,
      "ALTER TABLE training_sessions DROP CONSTRAINT training_sessions_relationship_parties_fkey"
    )

    create unique_index(:training_sessions, [:coach_profile_id, :client_request_id],
             name: :training_sessions_coach_request_index
           )

    # Keyset pages (start, then id) for each side, and the planned sessions
    # of a relationship (cancelled together when it ends).
    create index(:training_sessions, [:coach_profile_id, :starts_at, :id])
    create index(:training_sessions, [:fighter_profile_id, :starts_at, :id])

    create index(:training_sessions, [:coach_fighter_relationship_id, :starts_at],
             where: "status = 'planned'",
             name: :training_sessions_planned_by_relationship_index
           )

    create constraint(:training_sessions, :title_length,
             check: "char_length(title) BETWEEN 1 AND 80"
           )

    create constraint(:training_sessions, :training_type_values,
             check:
               "training_type IN ('technical', 'sparring', 'pads', 'strength_conditioning', 'roadwork')"
           )

    create constraint(:training_sessions, :duration_range,
             check: "duration_minutes BETWEEN 5 AND 600"
           )

    create constraint(:training_sessions, :notes_length,
             check: "notes IS NULL OR char_length(notes) BETWEEN 1 AND 2000"
           )

    create constraint(:training_sessions, :time_zone_length,
             check: "char_length(time_zone) BETWEEN 1 AND 64"
           )

    create constraint(:training_sessions, :status_values,
             check: "status IN ('planned', 'completed', 'cancelled')"
           )

    # The lifecycle shape: a planned row has no terminal facts; a completed
    # row has its completion only; a cancelled row has its cancellation only,
    # and a system cancellation always carries its reason.
    create constraint(:training_sessions, :lifecycle,
             check: """
             (status = 'planned' AND completed_at IS NULL AND cancelled_at IS NULL AND
              cancelled_by IS NULL AND cancel_reason IS NULL)
             OR
             (status = 'completed' AND completed_at IS NOT NULL AND cancelled_at IS NULL AND
              cancelled_by IS NULL AND cancel_reason IS NULL)
             OR
             (status = 'cancelled' AND completed_at IS NULL AND cancelled_at IS NOT NULL AND
              ((cancelled_by = 'coach' AND cancel_reason IS NULL) OR
               (cancelled_by = 'system' AND cancel_reason = 'relationship_ended')))
             """
           )

    # A session is created planned, under an active relationship, in a real
    # IANA zone. The relationship row is locked FOR SHARE: an end (FOR UPDATE)
    # either waits for this insert's transaction, then cancels the session, or
    # commits first, and the insert then sees it ended and fails.
    execute(
      """
      CREATE FUNCTION training_sessions_insert_guard() RETURNS trigger AS $$
      DECLARE
        relationship_status text;
      BEGIN
        IF NEW.status IS DISTINCT FROM 'planned' THEN
          RAISE EXCEPTION 'a training session starts planned'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'created_planned';
        END IF;

        SELECT status INTO relationship_status
          FROM coach_fighter_relationships
          WHERE id = NEW.coach_fighter_relationship_id
          FOR SHARE;

        IF relationship_status IS DISTINCT FROM 'active' THEN
          RAISE EXCEPTION 'a training session needs an active relationship'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'active_relationship';
        END IF;

        IF NOT training_sessions_valid_time_zone(NEW.time_zone) THEN
          RAISE EXCEPTION 'unknown time zone'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'time_zone_valid';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION training_sessions_insert_guard()"
    )

    # SF-49 §8.3: an IANA region id (or UTC) known to this server's zone data;
    # never an abbreviation or a POSIX, right/ or Etc/ entry.
    execute(
      """
      CREATE FUNCTION training_sessions_valid_time_zone(zone text) RETURNS boolean AS $$
        SELECT zone IS NOT NULL
          AND (zone = 'UTC' OR (zone ~ '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$'
                                AND zone !~ '^(posix|right|Etc)/'))
          AND EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = zone)
      $$ LANGUAGE sql STABLE
      """,
      "DROP FUNCTION training_sessions_valid_time_zone(text)"
    )

    execute(
      """
      CREATE TRIGGER training_sessions_insert_guard
      BEFORE INSERT ON training_sessions
      FOR EACH ROW EXECUTE FUNCTION training_sessions_insert_guard()
      """,
      "DROP TRIGGER training_sessions_insert_guard ON training_sessions"
    )

    # Owners, the relationship and the request key never change. A terminal
    # row is immutable. The only status changes are planned -> cancelled and
    # planned -> completed; the plan itself changes only while planned, and a
    # changed zone must still be valid.
    execute(
      """
      CREATE FUNCTION training_sessions_transition_guard() RETURNS trigger AS $$
      BEGIN
        IF OLD.status <> 'planned' THEN
          RAISE EXCEPTION 'a completed or cancelled training session is immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'terminal_immutable';
        END IF;

        IF NEW.coach_fighter_relationship_id IS DISTINCT FROM OLD.coach_fighter_relationship_id OR
           NEW.coach_profile_id IS DISTINCT FROM OLD.coach_profile_id OR
           NEW.fighter_profile_id IS DISTINCT FROM OLD.fighter_profile_id OR
           NEW.client_request_id IS DISTINCT FROM OLD.client_request_id OR
           NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
          RAISE EXCEPTION 'a training session keeps its owners'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'owners_immutable';
        END IF;

        IF NEW.status <> 'planned' AND (
             NEW.title IS DISTINCT FROM OLD.title OR
             NEW.training_type IS DISTINCT FROM OLD.training_type OR
             NEW.starts_at IS DISTINCT FROM OLD.starts_at OR
             NEW.time_zone IS DISTINCT FROM OLD.time_zone OR
             NEW.duration_minutes IS DISTINCT FROM OLD.duration_minutes OR
             NEW.notes IS DISTINCT FROM OLD.notes) THEN
          RAISE EXCEPTION 'a transition does not change the plan'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'transition_only';
        END IF;

        IF NEW.time_zone IS DISTINCT FROM OLD.time_zone AND
           NOT training_sessions_valid_time_zone(NEW.time_zone) THEN
          RAISE EXCEPTION 'unknown time zone'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'time_zone_valid';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION training_sessions_transition_guard()"
    )

    execute(
      """
      CREATE TRIGGER training_sessions_transition_guard
      BEFORE UPDATE ON training_sessions
      FOR EACH ROW EXECUTE FUNCTION training_sessions_transition_guard()
      """,
      "DROP TRIGGER training_sessions_transition_guard ON training_sessions"
    )
  end
end
