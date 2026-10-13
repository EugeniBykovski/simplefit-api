defmodule SimpleFit.Repo.Migrations.CreateCoachProfiles do
  use Ecto.Migration

  # SF-50: the coach profile and its resumable Coach onboarding (ADR 0020,
  # SF-49 §4.2 / §20). Independent of fighter profiles, account profiles and
  # any gym: no gym column, nothing created with the user.
  def change do
    create table(:coach_profiles) do
      # A profile cannot outlive its user. One user has at most one coach
      # profile (unique index below); creating a user never creates one.
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # Public coach identity. Nullable: onboarding is saved as the coach goes
      # and the required fields are checked only on completion.
      add :display_name, :text
      add :brand_name, :text
      add :country_code, :text
      add :city, :text
      add :bio, :text

      # Plain text arrays, not PostgreSQL enums: the vocabularies are enforced
      # by the domain, so a new value needs no migration (as for
      # fighter_profiles.goals).
      add :languages, {:array, :text}, null: false, default: []
      add :coaching_formats, {:array, :text}, null: false, default: []
      add :competition_levels, {:array, :text}, null: false, default: []

      # Set only by completing onboarding, after the domain has checked every
      # requirement; never accepted from a client.
      add :onboarding_completed_at, :utc_datetime

      timestamps()
    end

    create unique_index(:coach_profiles, [:user_id])

    # Shape only; the domain checks the ISO 3166-1 alpha-2 allowlist.
    create constraint(:coach_profiles, :country_code_format,
             check: "country_code IS NULL OR country_code ~ '^[A-Z]{2}$'"
           )

    # Lengths in characters (code points), as the domain counts them.
    create constraint(:coach_profiles, :display_name_length,
             check: "display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 60"
           )

    create constraint(:coach_profiles, :brand_name_length,
             check: "brand_name IS NULL OR char_length(brand_name) BETWEEN 1 AND 80"
           )

    create constraint(:coach_profiles, :city_length,
             check: "city IS NULL OR char_length(city) BETWEEN 1 AND 80"
           )

    create constraint(:coach_profiles, :bio_length,
             check: "bio IS NULL OR char_length(bio) BETWEEN 1 AND 500"
           )

    # Selections never hold NULL elements.
    create constraint(:coach_profiles, :selections_without_nulls,
             check: """
             array_position(languages, NULL) IS NULL AND
             array_position(coaching_formats, NULL) IS NULL AND
             array_position(competition_levels, NULL) IS NULL
             """
           )

    # The completion invariant, also enforced by the database: a completed
    # onboarding always has every required field and at least one format.
    create constraint(:coach_profiles, :completed_onboarding_requirements,
             check: """
             onboarding_completed_at IS NULL OR (
               display_name IS NOT NULL AND country_code IS NOT NULL AND
               city IS NOT NULL AND cardinality(coaching_formats) >= 1
             )
             """
           )

    # Completion is recorded once: the time can neither change nor be
    # removed afterwards.
    execute(
      """
      CREATE FUNCTION coach_profiles_completion_immutable() RETURNS trigger AS $$
      BEGIN
        IF OLD.onboarding_completed_at IS NOT NULL AND
           NEW.onboarding_completed_at IS DISTINCT FROM OLD.onboarding_completed_at THEN
          RAISE EXCEPTION 'onboarding completion is immutable'
            USING ERRCODE = 'check_violation',
                  CONSTRAINT = 'onboarding_completed_at_immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION coach_profiles_completion_immutable()"
    )

    execute(
      """
      CREATE TRIGGER coach_profiles_completion_immutable
      BEFORE UPDATE OF onboarding_completed_at ON coach_profiles
      FOR EACH ROW EXECUTE FUNCTION coach_profiles_completion_immutable()
      """,
      "DROP TRIGGER coach_profiles_completion_immutable ON coach_profiles"
    )
  end
end
