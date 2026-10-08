defmodule SimpleFit.Repo.Migrations.CreateAccountProfilesAndConsents do
  use Ecto.Migration

  # SF-44: shared account registration basics and consent history (ADR 0016).
  def change do
    create table(:account_profiles) do
      # One account profile per user, deleted with the user. Creating a user
      # never creates one: a user without it has not started registration.
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # Nullable: registration is saved as the person goes; both are required
      # only to complete it.
      add :full_name, :text
      add :date_of_birth, :date

      # Set only by completing registration, after every requirement is checked.
      add :registration_completed_at, :utc_datetime

      timestamps()
    end

    create unique_index(:account_profiles, [:user_id])

    # A completed registration always has its required fields.
    create constraint(:account_profiles, :completed_registration_requirements,
             check:
               "registration_completed_at IS NULL OR (full_name IS NOT NULL AND date_of_birth IS NOT NULL)"
           )

    # Once registration is complete, the completion time and the date of
    # birth can no longer change (corrections are a support concern).
    execute(
      """
      CREATE FUNCTION account_profiles_completed_immutable() RETURNS trigger AS $$
      BEGIN
        IF OLD.registration_completed_at IS NOT NULL AND (
             NEW.registration_completed_at IS DISTINCT FROM OLD.registration_completed_at OR
             NEW.date_of_birth IS DISTINCT FROM OLD.date_of_birth) THEN
          RAISE EXCEPTION 'completed account registration is immutable'
            USING ERRCODE = 'check_violation',
                  CONSTRAINT = 'account_profiles_completed_immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION account_profiles_completed_immutable()"
    )

    execute(
      """
      CREATE TRIGGER account_profiles_completed_immutable
      BEFORE UPDATE ON account_profiles
      FOR EACH ROW EXECUTE FUNCTION account_profiles_completed_immutable()
      """,
      "DROP TRIGGER account_profiles_completed_immutable ON account_profiles"
    )

    # Append-only consent decisions. Keyed by user (consent belongs to the
    # person, not to a profile row) and deleted with the user.
    create table(:account_consents) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Plain text, enforced by the domain (as identities.provider).
      add :kind, :text, null: false
      add :document_version, :text
      add :decision, :text, null: false
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create index(:account_consents, [:user_id, :kind, :recorded_at])

    create constraint(:account_consents, :decision_value,
             check: "decision IN ('accepted', 'withdrawn')"
           )

    # Required legal documents carry their version and are never withdrawn;
    # preferences (product news) have no document version.
    create constraint(:account_consents, :required_consent_shape,
             check: """
             (kind IN ('terms', 'privacy') AND document_version IS NOT NULL AND decision = 'accepted')
             OR (kind NOT IN ('terms', 'privacy') AND document_version IS NULL)
             """
           )

    # History is append-only: rows are never updated. Deletion stays possible
    # so a deleted user's records cascade away.
    execute(
      """
      CREATE FUNCTION account_consents_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'account consent history is append-only'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'account_consents_append_only';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION account_consents_append_only()"
    )

    execute(
      """
      CREATE TRIGGER account_consents_append_only
      BEFORE UPDATE ON account_consents
      FOR EACH ROW EXECUTE FUNCTION account_consents_append_only()
      """,
      "DROP TRIGGER account_consents_append_only ON account_consents"
    )
  end
end
