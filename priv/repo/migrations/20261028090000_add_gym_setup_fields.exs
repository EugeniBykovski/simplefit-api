defmodule SimpleFit.Repo.Migrations.AddGymSetupFields do
  use Ecto.Migration

  # SF-85: gym owner registration and setup (ADR 0026 D-G05, D-G21; SF-82
  # design checklist C2-C5). Additive and reversible:
  #
  #   * optional OG1 contact fields (`phone`, `website`) and OG3 text
  #     branding (`tagline`, `accent_color` from the approved six-swatch
  #     palette); logo and cover wait for a storage attachment mechanism;
  #   * `revision`, bumped by every setup change, for optimistic concurrency;
  #   * completion requires an active primary location, checked by the
  #     database when a gym leaves `draft`, and a completed gym can never lose
  #     its last active primary location;
  #   * audit event types for the setup transitions.
  #
  # Existing drafts stay valid: every new column is nullable or defaulted.
  # Rolling back drops the new columns and the new audit rows.

  @palette ~w(#aeb95a #e3a24f #e07a5f #7fa7c9 #edefe7 #8d9840)

  def up do
    alter table(:gyms) do
      add :phone, :text
      add :website, :text
      add :tagline, :text
      add :accent_color, :text
      add :revision, :integer, null: false, default: 1
    end

    create constraint(:gyms, :phone_format,
             check: "phone IS NULL OR phone ~ '^\\+?[0-9][0-9 ()-]{4,30}$'"
           )

    create constraint(:gyms, :website_format,
             check:
               "website IS NULL OR (char_length(website) <= 200 AND website ~ '^https?://[^\\s/?#@]+')"
           )

    create constraint(:gyms, :tagline_length,
             check:
               "tagline IS NULL OR (char_length(tagline) BETWEEN 1 AND 120 AND tagline = btrim(tagline))"
           )

    create constraint(:gyms, :accent_color_values,
             check:
               "accent_color IS NULL OR accent_color IN (" <>
                 Enum.map_join(@palette, ", ", &"'#{&1}'") <> ")"
           )

    create constraint(:gyms, :revision_positive, check: "revision > 0")

    # A draft becomes completed only with an active primary location.
    execute("""
    CREATE FUNCTION gyms_check_completion() RETURNS trigger AS $$
    BEGIN
      IF OLD.setup_status = 'draft' AND NEW.setup_status = 'completed' AND NOT EXISTS (
           SELECT 1 FROM gym_locations
            WHERE gym_id = NEW.id AND is_primary AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'a gym needs an active primary location to complete setup'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gyms_completion_requirements';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gyms_check_completion
    BEFORE UPDATE OF setup_status ON gyms
    FOR EACH ROW EXECUTE FUNCTION gyms_check_completion()
    """)

    # A completed gym keeps an active primary location: it cannot be archived,
    # demoted or deleted (deleting the gym itself takes its locations along).
    execute("""
    CREATE FUNCTION gym_locations_keep_primary() RETURNS trigger AS $$
    BEGIN
      IF OLD.is_primary AND OLD.archived_at IS NULL
         AND (TG_OP = 'DELETE' OR NOT NEW.is_primary OR NEW.archived_at IS NOT NULL)
         AND EXISTS (SELECT 1 FROM gyms WHERE id = OLD.gym_id AND setup_status = 'completed')
         AND NOT EXISTS (
           SELECT 1 FROM gym_locations
            WHERE gym_id = OLD.gym_id AND id <> OLD.id AND is_primary AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'a completed gym keeps an active primary location'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_locations_keep_primary';
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_locations_keep_primary
    BEFORE UPDATE OR DELETE ON gym_locations
    FOR EACH ROW EXECUTE FUNCTION gym_locations_keep_primary()
    """)

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', 'ownership_transferred', " <>
                 "'staff_membership_ended', 'primary_location_set', 'setup_completed', 'draft_discarded')"
           )
  end

  def down do
    execute(
      "DELETE FROM gym_audit_events WHERE event_type IN ('primary_location_set', 'setup_completed', 'draft_discarded')"
    )

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check:
               "event_type IN ('gym_created', 'staff_membership_created', " <>
                 "'ownership_transferred', 'staff_membership_ended')"
           )

    execute("DROP TRIGGER gym_locations_keep_primary ON gym_locations")
    execute("DROP FUNCTION gym_locations_keep_primary()")
    execute("DROP TRIGGER gyms_check_completion ON gyms")
    execute("DROP FUNCTION gyms_check_completion()")

    drop constraint(:gyms, :revision_positive)
    drop constraint(:gyms, :accent_color_values)
    drop constraint(:gyms, :tagline_length)
    drop constraint(:gyms, :website_format)
    drop constraint(:gyms, :phone_format)

    alter table(:gyms) do
      remove :revision
      remove :accent_color
      remove :tagline
      remove :website
      remove :phone
    end
  end
end
