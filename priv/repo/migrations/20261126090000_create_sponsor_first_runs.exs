defmodule SimpleFit.Repo.Migrations.CreateSponsorFirstRuns do
  use Ecto.Migration

  # SF-119: the partner portal first run (SRW1 welcome, SRW2 tour), per sponsor
  # organization and member, as the gym first run (SF-90) and ADR 0018. One row per
  # organization and user who started or ended the introduction; no step, device or
  # progress is stored.
  #
  #   * `started_at` - the member started the tour (null when dismissed unstarted);
  #   * `completed_at` / `dismissed_at` - the outcome, at most one, final once set;
  #   * no row means "not started".
  #
  # The row goes with its organization and its user (personal presentation state).
  # It grants nothing. Additive and reversible: rolling back drops the table.

  def up do
    create table(:sponsor_first_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:sponsor_organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :dismissed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sponsor_first_runs, [:organization_id, :user_id])
    create index(:sponsor_first_runs, [:user_id])

    create constraint(:sponsor_first_runs, :one_outcome,
             check: "completed_at IS NULL OR dismissed_at IS NULL"
           )

    create constraint(:sponsor_first_runs, :something_happened,
             check:
               "started_at IS NOT NULL OR completed_at IS NOT NULL OR dismissed_at IS NOT NULL"
           )

    create constraint(:sponsor_first_runs, :completed_was_started,
             check:
               "completed_at IS NULL OR (started_at IS NOT NULL AND completed_at >= started_at)"
           )

    create constraint(:sponsor_first_runs, :dismissed_after_start,
             check: "dismissed_at IS NULL OR started_at IS NULL OR dismissed_at >= started_at"
           )

    # Keys never move; a start is never rewritten; an outcome is final.
    execute("""
    CREATE FUNCTION sponsor_first_runs_guard() RETURNS trigger AS $$
    BEGIN
      IF NEW.organization_id <> OLD.organization_id OR NEW.user_id <> OLD.user_id THEN
        RAISE EXCEPTION 'a sponsor first run keeps its organization and user'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_first_runs_immutable_keys';
      END IF;
      IF OLD.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at THEN
        RAISE EXCEPTION 'a sponsor first run keeps its start'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_first_runs_immutable_start';
      END IF;
      IF OLD.completed_at IS NOT NULL OR OLD.dismissed_at IS NOT NULL THEN
        RAISE EXCEPTION 'a sponsor first run outcome is final'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_first_runs_final';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER sponsor_first_runs_guard
    BEFORE UPDATE ON sponsor_first_runs
    FOR EACH ROW EXECUTE FUNCTION sponsor_first_runs_guard()
    """)
  end

  def down do
    execute("DROP TRIGGER sponsor_first_runs_guard ON sponsor_first_runs")
    execute("DROP FUNCTION sponsor_first_runs_guard()")
    drop table(:sponsor_first_runs)
  end
end
