defmodule SimpleFit.Repo.Migrations.CreateGymFirstRuns do
  use Ecto.Migration

  # SF-90: the gym first run (ADR 0026 D-G21, ADR 0018 pattern). One row per
  # gym and owner who started or ended the introduction; nothing about the
  # checklist is stored (it is derived from the gym's own records).
  #
  #   * `started_at` - the owner started the introduction (null when it was
  #     dismissed without being started);
  #   * `completed_at` / `dismissed_at` - the terminal outcome, at most one,
  #     final once set;
  #   * a row exists only once something happened: no row is "not started".
  #
  # The row goes with its gym (a discarded draft never has one) and with its
  # user (personal presentation state, like `first_run_outcomes`). Additive
  # and reversible: rolling back drops the table and the two audit types.

  def up do
    create table(:gym_first_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :gym_id, references(:gyms, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :dismissed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_first_runs, [:gym_id, :user_id])
    create index(:gym_first_runs, [:user_id])

    create constraint(:gym_first_runs, :one_outcome,
             check: "completed_at IS NULL OR dismissed_at IS NULL"
           )

    create constraint(:gym_first_runs, :something_happened,
             check:
               "started_at IS NOT NULL OR completed_at IS NOT NULL OR dismissed_at IS NOT NULL"
           )

    create constraint(:gym_first_runs, :completed_was_started,
             check:
               "completed_at IS NULL OR (started_at IS NOT NULL AND completed_at >= started_at)"
           )

    create constraint(:gym_first_runs, :dismissed_after_start,
             check: "dismissed_at IS NULL OR started_at IS NULL OR dismissed_at >= started_at"
           )

    # Keys never move; a start is never rewritten; an outcome is final.
    execute("""
    CREATE FUNCTION gym_first_runs_guard() RETURNS trigger AS $$
    BEGIN
      IF NEW.gym_id <> OLD.gym_id OR NEW.user_id <> OLD.user_id THEN
        RAISE EXCEPTION 'a gym first run keeps its gym and user'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_first_runs_immutable_keys';
      END IF;
      IF OLD.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at THEN
        RAISE EXCEPTION 'a gym first run keeps its start'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_first_runs_immutable_start';
      END IF;
      IF OLD.completed_at IS NOT NULL OR OLD.dismissed_at IS NOT NULL THEN
        RAISE EXCEPTION 'a gym first run outcome is final'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_first_runs_final';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_first_runs_guard
    BEFORE UPDATE ON gym_first_runs
    FOR EACH ROW EXECUTE FUNCTION gym_first_runs_guard()
    """)

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', 'ownership_transferred', " <>
                 "'staff_membership_ended', 'primary_location_set', 'setup_completed', 'draft_discarded', " <>
                 "'first_run_completed', 'first_run_dismissed')"
           )
  end

  def down do
    execute(
      "DELETE FROM gym_audit_events WHERE event_type IN ('first_run_completed', 'first_run_dismissed')"
    )

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', 'ownership_transferred', " <>
                 "'staff_membership_ended', 'primary_location_set', 'setup_completed', 'draft_discarded')"
           )

    execute("DROP TRIGGER gym_first_runs_guard ON gym_first_runs")
    execute("DROP FUNCTION gym_first_runs_guard()")
    drop table(:gym_first_runs)
  end
end
