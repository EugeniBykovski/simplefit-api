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
      add :bout_count, :integer
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
    # Usernames are stored in canonical lowercase form, so this index is
    # case-insensitive in effect.
    create unique_index(:fighter_profiles, [:username], where: "username IS NOT NULL")

    create constraint(:fighter_profiles, :username_format,
             check: "username IS NULL OR username ~ '^[a-z][a-z0-9_]{2,29}$'"
           )

    create constraint(:fighter_profiles, :country_code_format,
             check: "country_code IS NULL OR country_code ~ '^[A-Z]{2}$'"
           )

    create constraint(:fighter_profiles, :bout_count_range,
             check: "bout_count IS NULL OR bout_count BETWEEN 0 AND 500"
           )

    create constraint(:fighter_profiles, :current_weight_kg_range,
             check: "current_weight_kg IS NULL OR current_weight_kg BETWEEN 30 AND 200"
           )

    create constraint(:fighter_profiles, :height_cm_range,
             check: "height_cm IS NULL OR height_cm BETWEEN 120 AND 230"
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
  end
end
