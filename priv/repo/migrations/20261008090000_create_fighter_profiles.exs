defmodule SimpleFit.Repo.Migrations.CreateFighterProfiles do
  use Ecto.Migration

  # SF-25: the fighter profile and its resumable onboarding (ADR 0015).
  def change do
    create table(:fighter_profiles) do
      # A profile cannot outlive its user. One user has at most one fighter
      # profile (unique index below); creating a user never creates one.
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # OF1 · account (public fighter identity). Nullable: onboarding is saved
      # as the fighter goes and these are required only to complete it.
      add :display_name, :text
      add :username, :text
      add :country_code, :text
      add :city, :text

      # OF2-OF4 · boxing profile. Plain text, not PostgreSQL enums: the
      # vocabularies are enforced by the domain, so a new value needs no
      # migration (as for identities.provider).
      add :experience_level, :text
      # OF2 records bouts on the Competitive Amateur option: an amateur record.
      add :amateur_bout_count, :integer
      add :stance, :text
      add :goals, {:array, :text}, null: false, default: []
      add :next_fight_on, :date
      add :next_fight_name, :text
      # Private body data: only the fighter (and later a coach they approve).
      add :weight_class, :text
      add :current_weight_kg, :decimal, precision: 4, scale: 1
      add :height_cm, :integer

      # Set only by completing onboarding, after the domain has checked every
      # requirement; never accepted from a client.
      add :onboarding_completed_at, :utc_datetime

      timestamps()
    end

    create unique_index(:fighter_profiles, [:user_id])
    # Case-insensitive uniqueness, independent of how the domain canonicalises.
    create unique_index(:fighter_profiles, ["lower(username)"],
             name: :fighter_profiles_username_index,
             where: "username IS NOT NULL"
           )

    # Canonical username: 3-30 lowercase ASCII letters, digits or underscores,
    # starting and ending with a letter or digit.
    create constraint(:fighter_profiles, :username_format,
             check: "username IS NULL OR username ~ '^[a-z0-9][a-z0-9_]{1,28}[a-z0-9]$'"
           )

    # Shape only; the domain checks the ISO 3166-1 alpha-2 allowlist.
    create constraint(:fighter_profiles, :country_code_format,
             check: "country_code IS NULL OR country_code ~ '^[A-Z]{2}$'"
           )

    # Technical validity only (no boxing or eligibility policy): counts are
    # not negative, body measurements are positive.
    create constraint(:fighter_profiles, :amateur_bout_count_non_negative,
             check: "amateur_bout_count IS NULL OR amateur_bout_count >= 0"
           )

    create constraint(:fighter_profiles, :current_weight_kg_positive,
             check: "current_weight_kg IS NULL OR current_weight_kg > 0"
           )

    create constraint(:fighter_profiles, :height_cm_positive,
             check: "height_cm IS NULL OR height_cm > 0"
           )

    # The completion invariant, also enforced by the database: a completed
    # onboarding always has every required field.
    create constraint(:fighter_profiles, :completed_onboarding_requirements,
             check: """
             onboarding_completed_at IS NULL OR (
               display_name IS NOT NULL AND username IS NOT NULL AND
               country_code IS NOT NULL AND city IS NOT NULL AND
               experience_level IS NOT NULL AND stance IS NOT NULL
             )
             """
           )

    # Completion is recorded once: the time can neither change nor be
    # removed afterwards.
    execute(
      """
      CREATE FUNCTION fighter_profiles_completion_immutable() RETURNS trigger AS $$
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
      "DROP FUNCTION fighter_profiles_completion_immutable()"
    )

    execute(
      """
      CREATE TRIGGER fighter_profiles_completion_immutable
      BEFORE UPDATE OF onboarding_completed_at ON fighter_profiles
      FOR EACH ROW EXECUTE FUNCTION fighter_profiles_completion_immutable()
      """,
      "DROP TRIGGER fighter_profiles_completion_immutable ON fighter_profiles"
    )
  end
end
