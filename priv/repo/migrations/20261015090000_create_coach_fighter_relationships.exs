defmodule SimpleFit.Repo.Migrations.CreateCoachFighterRelationships do
  use Ecto.Migration

  # SF-56: Coach–Fighter relationships (ADR 0021; SF-49 §6). One row is one
  # explicitly accepted coaching relationship between a completed coach
  # profile and a completed fighter profile: `active`, then `ended`
  # (terminal). A pending invitation is never a row here, and nothing links a
  # relationship to a gym. A reconnection after an end inserts a new row, so
  # ended rows are the history.
  def change do
    create table(:coach_fighter_relationships) do
      # A relationship cannot outlive either profile (and so either user).
      add :coach_profile_id, references(:coach_profiles, on_delete: :delete_all), null: false
      add :fighter_profile_id, references(:fighter_profiles, on_delete: :delete_all), null: false

      add :status, :text, null: false

      # The fighter's acceptance: the disclosure version they accepted (an
      # identifier configured from the approved legal text, never a client
      # value) and when. The coach projection never exceeds that version.
      add :disclosure_version, :text, null: false
      add :started_at, :utc_datetime_usec, null: false

      # Set once, by ending.
      add :ended_at, :utc_datetime_usec
      add :ended_by, :text

      # The minimum history kept after an end (SF-49 §6.4.4): each side's
      # name as it was when the relationship ended. Never refreshed.
      add :fighter_display_name_at_end, :text
      add :coach_display_name_at_end, :text

      timestamps(type: :utc_datetime_usec)
    end

    # At most one active relationship per pair; ended rows (history) are not
    # restricted, so a pair can reconnect.
    create unique_index(:coach_fighter_relationships, [:coach_profile_id, :fighter_profile_id],
             where: "status = 'active'",
             name: :coach_fighter_relationships_active_pair_index
           )

    create index(:coach_fighter_relationships, [:coach_profile_id, :status])
    create index(:coach_fighter_relationships, [:fighter_profile_id, :status])

    create constraint(:coach_fighter_relationships, :status_values,
             check: "status IN ('active', 'ended')"
           )

    create constraint(:coach_fighter_relationships, :ended_by_values,
             check: "ended_by IS NULL OR ended_by IN ('coach', 'fighter')"
           )

    create constraint(:coach_fighter_relationships, :disclosure_version_length,
             check: "char_length(disclosure_version) BETWEEN 1 AND 64"
           )

    # The lifecycle shape: an active row has no end facts; an ended row has
    # all of them, never before it started.
    create constraint(:coach_fighter_relationships, :lifecycle,
             check: """
             (status = 'active' AND ended_at IS NULL AND ended_by IS NULL AND
              fighter_display_name_at_end IS NULL AND coach_display_name_at_end IS NULL)
             OR
             (status = 'ended' AND ended_at IS NOT NULL AND ended_by IS NOT NULL AND
              ended_at >= started_at)
             """
           )

    # A relationship is created active, between two completed profiles of
    # two different users (no self-coaching, even for a user holding both
    # profiles). Checked by the database, not only by the domain.
    execute(
      """
      CREATE FUNCTION coach_fighter_relationships_insert_guard() RETURNS trigger AS $$
      DECLARE
        coach_user uuid;
        coach_completed timestamp;
        fighter_user uuid;
        fighter_completed timestamp;
      BEGIN
        IF NEW.status IS DISTINCT FROM 'active' THEN
          RAISE EXCEPTION 'a relationship starts active'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'created_active';
        END IF;

        SELECT user_id, onboarding_completed_at INTO coach_user, coach_completed
          FROM coach_profiles WHERE id = NEW.coach_profile_id;
        SELECT user_id, onboarding_completed_at INTO fighter_user, fighter_completed
          FROM fighter_profiles WHERE id = NEW.fighter_profile_id;

        IF coach_completed IS NULL OR fighter_completed IS NULL THEN
          RAISE EXCEPTION 'both profiles must be completed'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'completed_profiles';
        END IF;

        IF coach_user = fighter_user THEN
          RAISE EXCEPTION 'a user cannot coach themselves'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'no_self_coaching';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION coach_fighter_relationships_insert_guard()"
    )

    execute(
      """
      CREATE TRIGGER coach_fighter_relationships_insert_guard
      BEFORE INSERT ON coach_fighter_relationships
      FOR EACH ROW EXECUTE FUNCTION coach_fighter_relationships_insert_guard()
      """,
      "DROP TRIGGER coach_fighter_relationships_insert_guard ON coach_fighter_relationships"
    )

    # The only change a row ever takes is its end (active -> ended). Who and
    # what was accepted never change, and an ended row is immutable: it can
    # never be reactivated or rewritten.
    execute(
      """
      CREATE FUNCTION coach_fighter_relationships_transition_guard() RETURNS trigger AS $$
      BEGIN
        IF OLD.status = 'ended' THEN
          RAISE EXCEPTION 'an ended relationship is immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'ended_immutable';
        END IF;

        IF NEW.status IS DISTINCT FROM 'ended' OR
           NEW.coach_profile_id IS DISTINCT FROM OLD.coach_profile_id OR
           NEW.fighter_profile_id IS DISTINCT FROM OLD.fighter_profile_id OR
           NEW.disclosure_version IS DISTINCT FROM OLD.disclosure_version OR
           NEW.started_at IS DISTINCT FROM OLD.started_at THEN
          RAISE EXCEPTION 'a relationship can only be ended'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'end_only';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION coach_fighter_relationships_transition_guard()"
    )

    execute(
      """
      CREATE TRIGGER coach_fighter_relationships_transition_guard
      BEFORE UPDATE ON coach_fighter_relationships
      FOR EACH ROW EXECUTE FUNCTION coach_fighter_relationships_transition_guard()
      """,
      "DROP TRIGGER coach_fighter_relationships_transition_guard ON coach_fighter_relationships"
    )
  end
end
