defmodule SimpleFit.Repo.Migrations.CreateSponsorOrganizations do
  @moduledoc """
  SF-112: the sponsor organization and workspace foundation (ADR 0030, from the
  proposed ADR 0027 / SF-107 ERD). No application table: that is the Sponsor
  Application task's.

  * `sponsor_organizations` - an approved business. Provisioned only through
    `SimpleFit.Sponsors.Provisioning` (no public endpoint). `provisioning_source`
    says by what: `sponsor_application` (the future approval transaction; then
    `source_application_id`, unique, is required; its foreign key arrives with the
    application table) or `local_fixture` (development and test builds only; never
    trusted). `provisioning_key` makes a repeated provisioning idempotent. Status
    `active` -> `suspended` <-> `active`, either -> `closed` (terminal), by trigger.
    `revision` is raised by a trigger on every update. Never deleted.
  * `sponsor_workspace_memberships` - user x organization, role `owner`, `manager`
    or `member`, status `active` <-> `suspended` -> `revoked` (terminal). One
    non-revoked membership per user and organization, at most one non-revoked
    owner, and (checked at commit) exactly one active owner in every organization
    that isn't closed. Roles are immutable and the owner can't be suspended or
    revoked until ownership transfer exists (D-SA07). Never deleted.
  * `sponsor_contacts` - business contacts. Not users, not members: no user id,
    grants nothing. One `primary` contact per organization.
  * `sponsor_organization_events` - append-only business history of the
    organization (not the operator audit).
  * `entry_context_choices` gains `sponsor` with its `sponsor_organization_id`.

  The triggers bind the application's database role, not a superuser (D-SA28).
  """

  use Ecto.Migration

  def up do
    create table(:sponsor_organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legal_name, :text, null: false
      add :display_name, :text, null: false
      add :country_code, :text, null: false
      add :website, :text
      add :status, :text, null: false
      add :provisioning_source, :text, null: false
      add :source_application_id, :binary_id
      add :provisioning_key, :binary_id, null: false
      add :suspended_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
      add :revision, :bigint, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:sponsor_organizations, :fields,
             check:
               "char_length(legal_name) BETWEEN 1 AND 200 AND legal_name = btrim(legal_name) AND " <>
                 "char_length(display_name) BETWEEN 1 AND 120 AND display_name = btrim(display_name) AND " <>
                 "country_code ~ '^[A-Z]{2}$' AND " <>
                 "(website IS NULL OR (char_length(website) <= 200 AND website ~ '^https://'))"
           )

    create constraint(:sponsor_organizations, :status_values,
             check: "status IN ('active', 'suspended', 'closed')"
           )

    create constraint(:sponsor_organizations, :lifecycle,
             check:
               "(status <> 'suspended' OR suspended_at IS NOT NULL) AND " <>
                 "(status <> 'closed' OR closed_at IS NOT NULL)"
           )

    create constraint(:sponsor_organizations, :provisioning,
             check:
               "(provisioning_source = 'sponsor_application' AND source_application_id IS NOT NULL) OR " <>
                 "(provisioning_source = 'local_fixture' AND source_application_id IS NULL)"
           )

    create unique_index(:sponsor_organizations, [:provisioning_key])

    create unique_index(:sponsor_organizations, [:source_application_id],
             where: "source_application_id IS NOT NULL"
           )

    execute("""
    CREATE FUNCTION sponsor_organizations_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'sponsor organizations are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_organizations_no_delete';
      END IF;
      IF NEW.provisioning_source <> OLD.provisioning_source
         OR NEW.source_application_id IS DISTINCT FROM OLD.source_application_id
         OR NEW.provisioning_key <> OLD.provisioning_key THEN
        RAISE EXCEPTION 'an organization''s provisioning is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_organizations_immutable_provisioning';
      END IF;
      IF NEW.status <> OLD.status AND NOT (
           (OLD.status = 'active' AND NEW.status IN ('suspended', 'closed')) OR
           (OLD.status = 'suspended' AND NEW.status IN ('active', 'closed'))
         ) THEN
        RAISE EXCEPTION 'organization status % cannot become %', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_organizations_transition';
      END IF;
      NEW.revision := OLD.revision + 1;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_organizations_guard
      BEFORE UPDATE OR DELETE ON sponsor_organizations
      FOR EACH ROW EXECUTE FUNCTION sponsor_organizations_guard();
    """)

    create table(:sponsor_workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:sponsor_organizations, type: :binary_id, on_delete: :restrict),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :role, :text, null: false
      add :status, :text, null: false
      add :suspended_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :revoked_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:sponsor_workspace_memberships, :role_values,
             check: "role IN ('owner', 'manager', 'member')"
           )

    create constraint(:sponsor_workspace_memberships, :status_values,
             check: "status IN ('active', 'suspended', 'revoked')"
           )

    create constraint(:sponsor_workspace_memberships, :lifecycle,
             check:
               "(status <> 'suspended' OR suspended_at IS NOT NULL) AND " <>
                 "((status = 'revoked') = (revoked_at IS NOT NULL)) AND " <>
                 "((status = 'revoked') = (revoked_reason IS NOT NULL)) AND " <>
                 "(revoked_reason IS NULL OR revoked_reason ~ '^[a-z][a-z0-9_]{1,59}$')"
           )

    create unique_index(:sponsor_workspace_memberships, [:organization_id, :user_id],
             where: "status <> 'revoked'",
             name: :sponsor_workspace_memberships_one_per_user_index
           )

    create unique_index(:sponsor_workspace_memberships, [:organization_id],
             where: "role = 'owner' AND status <> 'revoked'",
             name: :sponsor_workspace_memberships_one_owner_index
           )

    create index(:sponsor_workspace_memberships, [:user_id], where: "status = 'active'")

    execute("""
    CREATE FUNCTION sponsor_workspace_memberships_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'sponsor memberships are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_workspace_memberships_no_delete';
      END IF;
      IF NEW.organization_id <> OLD.organization_id OR NEW.user_id <> OLD.user_id
         OR NEW.role <> OLD.role THEN
        RAISE EXCEPTION 'a membership''s organization, user and role are immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_workspace_memberships_immutable';
      END IF;
      IF NEW.status <> OLD.status AND NOT (
           (OLD.status = 'active' AND NEW.status IN ('suspended', 'revoked')) OR
           (OLD.status = 'suspended' AND NEW.status IN ('active', 'revoked'))
         ) THEN
        RAISE EXCEPTION 'membership status % cannot become %', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_workspace_memberships_transition';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_workspace_memberships_guard
      BEFORE UPDATE OR DELETE ON sponsor_workspace_memberships
      FOR EACH ROW EXECUTE FUNCTION sponsor_workspace_memberships_guard();
    """)

    # Exactly one active owner in every organization that isn't closed, at commit:
    # provisioning inserts the organization and its owner in one transaction.
    execute("""
    CREATE FUNCTION sponsor_organizations_owner_check() RETURNS trigger AS $$
    DECLARE
      org_id uuid;
      org_status text;
      owners integer;
    BEGIN
      IF TG_TABLE_NAME = 'sponsor_organizations' THEN
        org_id := NEW.id;
      ELSE
        org_id := NEW.organization_id;
      END IF;
      SELECT status INTO org_status FROM sponsor_organizations WHERE id = org_id;
      IF org_status IS NOT NULL AND org_status <> 'closed' THEN
        SELECT count(*) INTO owners FROM sponsor_workspace_memberships
          WHERE organization_id = org_id AND role = 'owner' AND status = 'active';
        IF owners <> 1 THEN
          RAISE EXCEPTION 'organization % must have exactly one active owner', org_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_organizations_one_active_owner';
        END IF;
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER sponsor_organizations_owner_check
      AFTER INSERT OR UPDATE ON sponsor_organizations
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION sponsor_organizations_owner_check();
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER sponsor_workspace_memberships_owner_check
      AFTER INSERT OR UPDATE ON sponsor_workspace_memberships
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION sponsor_organizations_owner_check();
    """)

    create table(:sponsor_contacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:sponsor_organizations, type: :binary_id, on_delete: :restrict),
          null: false

      add :kind, :text, null: false
      add :full_name, :text, null: false
      add :job_title, :text
      add :email, :text, null: false
      add :phone, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:sponsor_contacts, :fields,
             check:
               "kind IN ('primary', 'additional') AND " <>
                 "char_length(full_name) BETWEEN 1 AND 120 AND full_name = btrim(full_name) AND " <>
                 "(job_title IS NULL OR char_length(job_title) BETWEEN 1 AND 120) AND " <>
                 "char_length(email) BETWEEN 3 AND 254 AND email = lower(btrim(email)) AND " <>
                 "position('@' IN email) > 1 AND " <>
                 "(phone IS NULL OR phone ~ '^\\+[1-9][0-9]{6,14}$')"
           )

    create unique_index(:sponsor_contacts, [:organization_id],
             where: "kind = 'primary'",
             name: :sponsor_contacts_one_primary_index
           )

    create table(:sponsor_organization_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:sponsor_organizations, type: :binary_id, on_delete: :restrict),
          null: false

      add :occurred_at, :utc_datetime_usec, null: false
      add :event, :text, null: false
      add :authority, :text, null: false
      add :actor_user_id, :binary_id
      add :membership_id, :binary_id
      add :subject_user_id, :binary_id
      add :role, :text
      add :from_state, :text
      add :to_state, :text
      add :reason_code, :text
      add :request_id, :text
    end

    create constraint(:sponsor_organization_events, :codes,
             check:
               "event ~ '^[a-z][a-z0-9_.]{1,79}$' AND " <>
                 "authority IN ('sponsor_application', 'local_fixture', 'organization_member', 'system') AND " <>
                 "(role IS NULL OR role IN ('owner', 'manager', 'member')) AND " <>
                 "(from_state IS NULL OR from_state ~ '^[a-z][a-z0-9_]{0,39}$') AND " <>
                 "(to_state IS NULL OR to_state ~ '^[a-z][a-z0-9_]{0,39}$') AND " <>
                 "(reason_code IS NULL OR reason_code ~ '^[a-z][a-z0-9_]{1,59}$') AND " <>
                 "(request_id IS NULL OR char_length(request_id) <= 200)"
           )

    create index(:sponsor_organization_events, [:organization_id, :occurred_at])

    execute("""
    CREATE FUNCTION sponsor_append_only() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_append_only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_organization_events_append_only
      BEFORE UPDATE OR DELETE ON sponsor_organization_events
      FOR EACH ROW EXECUTE FUNCTION sponsor_append_only();
    """)

    alter table(:entry_context_choices) do
      add :sponsor_organization_id,
          references(:sponsor_organizations, type: :binary_id, on_delete: :delete_all)
    end

    drop constraint(:entry_context_choices, :context_values)
    drop constraint(:entry_context_choices, :gym_choice_names_gym)

    create constraint(:entry_context_choices, :context_values,
             check: "context IN ('fighter', 'coach', 'gym', 'sponsor')"
           )

    create constraint(:entry_context_choices, :gym_choice_names_gym,
             check: "(context = 'gym') = (gym_id IS NOT NULL)"
           )

    create constraint(:entry_context_choices, :sponsor_choice_names_organization,
             check: "(context = 'sponsor') = (sponsor_organization_id IS NOT NULL)"
           )

    create index(:entry_context_choices, [:sponsor_organization_id])
  end

  def down do
    # Refused once an organization exists: sponsor history isn't destroyed by a rollback.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM sponsor_organizations) THEN
        RAISE EXCEPTION 'SF-112 rollback refused: sponsor organizations exist';
      END IF;
    END;
    $$;
    """)

    drop index(:entry_context_choices, [:sponsor_organization_id])
    drop constraint(:entry_context_choices, :sponsor_choice_names_organization)
    drop constraint(:entry_context_choices, :context_values)

    create constraint(:entry_context_choices, :context_values,
             check: "context IN ('fighter', 'coach', 'gym')"
           )

    alter table(:entry_context_choices) do
      remove :sponsor_organization_id
    end

    drop table(:sponsor_organization_events)
    execute("DROP FUNCTION sponsor_append_only()")
    drop table(:sponsor_contacts)
    drop table(:sponsor_workspace_memberships)
    execute("DROP FUNCTION sponsor_workspace_memberships_guard()")
    drop table(:sponsor_organizations)
    execute("DROP FUNCTION sponsor_organizations_owner_check()")
    execute("DROP FUNCTION sponsor_organizations_guard()")
  end
end
