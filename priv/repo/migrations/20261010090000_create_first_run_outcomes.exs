defmodule SimpleFit.Repo.Migrations.CreateFirstRunOutcomes do
  use Ecto.Migration

  # SF-40: how a user left a one-time first-run experience (ADR 0018).
  def change do
    create table(:first_run_outcomes) do
      # Deleted with the user. Nothing is added to users or to role profiles.
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Plain text, enforced by the domain (as identities.provider): a new
      # experience needs no migration.
      add :experience, :text, null: false
      add :outcome, :text, null: false
      add :recorded_at, :utc_datetime_usec, null: false
    end

    # One outcome per user and experience: the first one recorded is kept, so
    # concurrent and repeated requests can never record two.
    create unique_index(:first_run_outcomes, [:user_id, :experience])

    create constraint(:first_run_outcomes, :outcome_value,
             check: "outcome IN ('completed', 'dismissed')"
           )

    # An outcome is final: rows are never updated. Deletion stays possible so
    # a deleted user's records cascade away.
    execute(
      """
      CREATE FUNCTION first_run_outcomes_final() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'a first-run outcome is final'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'first_run_outcomes_final';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION first_run_outcomes_final()"
    )

    execute(
      """
      CREATE TRIGGER first_run_outcomes_final
      BEFORE UPDATE ON first_run_outcomes
      FOR EACH ROW EXECUTE FUNCTION first_run_outcomes_final()
      """,
      "DROP TRIGGER first_run_outcomes_final ON first_run_outcomes"
    )
  end
end
