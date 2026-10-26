defmodule SimpleFit.Repo.Migrations.CreateGymCreationRequests do
  use Ecto.Migration

  # SF-85: durable idempotency for gym creation. Every `client_request_id` a
  # user sends to createGym is recorded with the gym it produced or resumed.
  # Discarding that gym (a hard delete) only clears `gym_id`, so the key
  # stays spent: a replay can never create a new gym. Rows go with their
  # user; no retention period is invented (they hold no personal data).
  # Existing gyms are backfilled from `gyms.client_request_id`.
  def up do
    create table(:gym_creation_requests, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false, primary_key: true
      add :client_request_id, :binary_id, null: false, primary_key: true
      # NULL once the gym was discarded.
      add :gym_id, references(:gyms, on_delete: :nilify_all)
      add :outcome, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:gym_creation_requests, [:gym_id])

    create constraint(:gym_creation_requests, :outcome_values,
             check: "outcome IN ('created', 'resumed')"
           )

    execute("""
    INSERT INTO gym_creation_requests (user_id, client_request_id, gym_id, outcome, inserted_at)
    SELECT created_by_user_id, client_request_id, id, 'created', inserted_at
      FROM gyms
     WHERE created_by_user_id IS NOT NULL
    """)
  end

  def down do
    drop table(:gym_creation_requests)
  end
end
