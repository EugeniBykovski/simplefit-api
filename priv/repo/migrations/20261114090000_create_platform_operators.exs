defmodule SimpleFit.Repo.Migrations.CreatePlatformOperators do
  @moduledoc """
  SF-110: platform operators (ADR 0028), the authority SF-136 left missing.

  * `platform_operators` - one non-revoked row per user. Not a user column: no role,
    type or admin flag is added to `users`. Status transitions are a trigger;
    `revoked` is terminal and rows are never deleted.
  * `operator_credentials` - WebAuthn public keys only. A credential id is unique
    forever, so a revoked (possibly compromised) key can't be registered again.
  * `operator_webauthn_challenges` - server-side, one-time, bound to one operator
    and one session.
  * `operator_step_ups` - proof of a recent key check, bound to one session.
  * `operator_permission_grants` - one row per permission, from a catalog CHECK:
    a new permission needs a reviewed migration. Exactly one source (an operator
    or a signed ceremony), never the grantee itself.
  * `operator_ceremonies` - each signed bootstrap or recovery statement, consumable
    once.
  * `operator_operations` - client operation ids, so a repeated request does nothing.
  * `operator_audit_events` - append-only, no foreign keys, ids and codes only.

  These triggers bind the application's database role. A database superuser can
  still change any row: that boundary is infrastructure, not this migration.
  """

  use Ecto.Migration

  @permissions ~w(operators.read operators.manage audit.read)

  def up do
    create table(:platform_operators, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :status, :text, null: false
      add :bootstrap, :boolean, null: false, default: false

      add :created_by_operator_id,
          references(:platform_operators, type: :binary_id, on_delete: :restrict)

      add :ceremony_id, :binary_id
      add :enrollment_expires_at, :utc_datetime_usec
      add :activated_at, :utc_datetime_usec
      add :suspended_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:platform_operators, :status_values,
             check: "status IN ('pending_enrollment', 'active', 'suspended', 'revoked')"
           )

    create constraint(:platform_operators, :origin,
             check:
               "(bootstrap AND created_by_operator_id IS NULL AND ceremony_id IS NOT NULL) OR " <>
                 "(NOT bootstrap AND created_by_operator_id IS NOT NULL AND ceremony_id IS NULL)"
           )

    create constraint(:platform_operators, :not_self_created,
             check: "created_by_operator_id IS NULL OR created_by_operator_id <> id"
           )

    create constraint(:platform_operators, :lifecycle,
             check:
               "(status <> 'pending_enrollment' OR enrollment_expires_at IS NOT NULL) AND " <>
                 "(status <> 'active' OR activated_at IS NOT NULL) AND " <>
                 "(status <> 'suspended' OR suspended_at IS NOT NULL) AND " <>
                 "(status <> 'revoked' OR revoked_at IS NOT NULL)"
           )

    create unique_index(:platform_operators, [:user_id],
             where: "status <> 'revoked'",
             name: :platform_operators_one_per_user_index
           )

    create unique_index(:platform_operators, [:bootstrap],
             where: "bootstrap",
             name: :platform_operators_one_bootstrap_index
           )

    execute("""
    CREATE FUNCTION platform_operators_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'platform operators are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'platform_operators_no_delete';
      END IF;
      IF NEW.user_id <> OLD.user_id OR NEW.bootstrap <> OLD.bootstrap
         OR NEW.created_by_operator_id IS DISTINCT FROM OLD.created_by_operator_id
         OR NEW.ceremony_id IS DISTINCT FROM OLD.ceremony_id THEN
        RAISE EXCEPTION 'an operator''s origin is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'platform_operators_immutable_origin';
      END IF;
      IF NEW.status <> OLD.status AND NOT (
           (OLD.status = 'pending_enrollment' AND NEW.status IN ('active', 'revoked')) OR
           (OLD.status = 'active' AND NEW.status IN ('suspended', 'revoked', 'pending_enrollment')) OR
           (OLD.status = 'suspended' AND NEW.status IN ('active', 'revoked', 'pending_enrollment'))
         ) THEN
        RAISE EXCEPTION 'operator status % cannot become %', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'platform_operators_transition';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER platform_operators_guard
      BEFORE UPDATE OR DELETE ON platform_operators
      FOR EACH ROW EXECUTE FUNCTION platform_operators_guard();
    """)

    create table(:operator_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :operator_id, references(:platform_operators, type: :binary_id, on_delete: :restrict),
        null: false

      add :credential_id, :binary, null: false
      add :cose_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :aaguid, :binary
      add :label, :text, null: false
      add :backup_eligible, :boolean, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :revoked_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operator_credentials, [:credential_id])
    create index(:operator_credentials, [:operator_id], where: "revoked_at IS NULL")

    create constraint(:operator_credentials, :revocation,
             check: "(revoked_at IS NULL) = (revoked_reason IS NULL)"
           )

    create constraint(:operator_credentials, :label_length,
             check: "char_length(label) BETWEEN 1 AND 60"
           )

    create constraint(:operator_credentials, :sign_count_positive, check: "sign_count >= 0")

    execute("""
    CREATE FUNCTION operator_credentials_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'operator credentials are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'operator_credentials_no_delete';
      END IF;
      IF NEW.operator_id <> OLD.operator_id OR NEW.credential_id <> OLD.credential_id
         OR NEW.cose_key <> OLD.cose_key OR NEW.backup_eligible <> OLD.backup_eligible
         OR NEW.aaguid IS DISTINCT FROM OLD.aaguid
         OR (OLD.revoked_at IS NOT NULL AND (NEW.revoked_at IS DISTINCT FROM OLD.revoked_at
             OR NEW.revoked_reason IS DISTINCT FROM OLD.revoked_reason))
         OR NEW.sign_count < OLD.sign_count THEN
        RAISE EXCEPTION 'an operator credential only records use and revocation'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'operator_credentials_immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER operator_credentials_guard
      BEFORE UPDATE OR DELETE ON operator_credentials
      FOR EACH ROW EXECUTE FUNCTION operator_credentials_guard();
    """)

    create table(:operator_webauthn_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :operator_id, references(:platform_operators, type: :binary_id, on_delete: :restrict),
        null: false

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :purpose, :text, null: false
      add :challenge, :binary, null: false
      add :issued_at, :bigint, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:operator_webauthn_challenges, :purpose_values,
             check: "purpose IN ('registration', 'step_up')"
           )

    create index(:operator_webauthn_challenges, [:operator_id, :session_id])
    create index(:operator_webauthn_challenges, [:expires_at])

    create table(:operator_step_ups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :operator_id, references(:platform_operators, type: :binary_id, on_delete: :restrict),
        null: false

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credential_id,
          references(:operator_credentials, type: :binary_id, on_delete: :restrict), null: false

      add :verified_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:operator_step_ups, [:session_id, :operator_id])
    create index(:operator_step_ups, [:operator_id], where: "revoked_at IS NULL")

    create constraint(:operator_step_ups, :window, check: "expires_at > verified_at")

    create table(:operator_permission_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :operator_id, references(:platform_operators, type: :binary_id, on_delete: :restrict),
        null: false

      add :permission, :text, null: false

      add :granted_by_operator_id,
          references(:platform_operators, type: :binary_id, on_delete: :restrict)

      add :ceremony_id, :binary_id
      add :reason_code, :text, null: false
      add :operation_id, :binary_id, null: false
      add :granted_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec

      add :revoked_by_operator_id,
          references(:platform_operators, type: :binary_id, on_delete: :restrict)

      add :revoke_reason_code, :text
    end

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{Enum.map_join(@permissions, ", ", &"'#{&1}'")})"
           )

    create constraint(:operator_permission_grants, :one_source,
             check: "(granted_by_operator_id IS NULL) <> (ceremony_id IS NULL)"
           )

    create constraint(:operator_permission_grants, :no_self_grant,
             check: "granted_by_operator_id IS NULL OR granted_by_operator_id <> operator_id"
           )

    create constraint(:operator_permission_grants, :revocation,
             check:
               "(revoked_at IS NULL AND revoke_reason_code IS NULL AND revoked_by_operator_id IS NULL) OR " <>
                 "(revoked_at IS NOT NULL AND revoke_reason_code IS NOT NULL)"
           )

    create constraint(:operator_permission_grants, :reason_codes,
             check:
               "reason_code ~ '^[a-z][a-z0-9_]{1,59}$' AND " <>
                 "(revoke_reason_code IS NULL OR revoke_reason_code ~ '^[a-z][a-z0-9_]{1,59}$')"
           )

    create unique_index(:operator_permission_grants, [:operator_id, :permission],
             where: "revoked_at IS NULL",
             name: :operator_permission_grants_one_active_index
           )

    execute("""
    CREATE FUNCTION operator_permission_grants_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'permission grants are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'operator_permission_grants_no_delete';
      END IF;
      IF OLD.revoked_at IS NOT NULL
         OR NEW.operator_id <> OLD.operator_id OR NEW.permission <> OLD.permission
         OR NEW.granted_by_operator_id IS DISTINCT FROM OLD.granted_by_operator_id
         OR NEW.ceremony_id IS DISTINCT FROM OLD.ceremony_id
         OR NEW.reason_code <> OLD.reason_code OR NEW.operation_id <> OLD.operation_id
         OR NEW.granted_at <> OLD.granted_at THEN
        RAISE EXCEPTION 'a permission grant can only be revoked, once'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'operator_permission_grants_immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER operator_permission_grants_guard
      BEFORE UPDATE OR DELETE ON operator_permission_grants
      FOR EACH ROW EXECUTE FUNCTION operator_permission_grants_guard();
    """)

    create table(:operator_ceremonies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :purpose, :text, null: false
      add :key_id, :text, null: false
      add :environment, :text, null: false
      add :statement_sha256, :binary, null: false
      add :target_user_id, :binary_id, null: false

      add :operator_id, references(:platform_operators, type: :binary_id, on_delete: :restrict),
        null: false

      add :consumed_at, :utc_datetime_usec, null: false
    end

    create constraint(:operator_ceremonies, :purpose_values,
             check: "purpose IN ('bootstrap', 'recovery')"
           )

    create unique_index(:operator_ceremonies, [:statement_sha256])

    execute("""
    CREATE FUNCTION operator_append_only() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_append_only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER operator_ceremonies_append_only
      BEFORE UPDATE OR DELETE ON operator_ceremonies
      FOR EACH ROW EXECUTE FUNCTION operator_append_only();
    """)

    create table(:operator_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :actor_operator_id,
          references(:platform_operators, type: :binary_id, on_delete: :restrict), null: false

      add :action, :text, null: false
      add :target_id, :binary_id, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute("""
    CREATE TRIGGER operator_operations_append_only
      BEFORE UPDATE OR DELETE ON operator_operations
      FOR EACH ROW EXECUTE FUNCTION operator_append_only();
    """)

    create table(:operator_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :occurred_at, :utc_datetime_usec, null: false
      add :action, :text, null: false
      add :outcome, :text, null: false
      add :authority, :text, null: false
      add :actor_operator_id, :binary_id
      add :actor_user_id, :binary_id
      add :permission, :text
      add :target_type, :text
      add :target_id, :binary_id
      add :reason_code, :text
      add :operation_id, :binary_id
      add :session_id, :binary_id
      add :ceremony_id, :binary_id
      add :request_id, :text
    end

    create constraint(:operator_audit_events, :outcome_values,
             check: "outcome IN ('allowed', 'refused')"
           )

    create constraint(:operator_audit_events, :authority_values,
             check:
               "authority IN ('platform_operator', 'signed_ceremony', 'local_development_ceremony', 'system')"
           )

    create constraint(:operator_audit_events, :codes,
             check:
               "action ~ '^[a-z][a-z0-9_.]{1,79}$' AND " <>
                 "(reason_code IS NULL OR reason_code ~ '^[a-z][a-z0-9_]{1,59}$') AND " <>
                 "(request_id IS NULL OR char_length(request_id) <= 200)"
           )

    create index(:operator_audit_events, [:occurred_at])
    create index(:operator_audit_events, [:actor_operator_id, :occurred_at])
    create index(:operator_audit_events, [:target_id, :occurred_at])

    execute("""
    CREATE TRIGGER operator_audit_events_append_only
      BEFORE UPDATE OR DELETE ON operator_audit_events
      FOR EACH ROW EXECUTE FUNCTION operator_append_only();
    """)
  end

  def down do
    # Refused once any operator or audit event exists: history isn't destroyed by a rollback.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM platform_operators) OR EXISTS (SELECT 1 FROM operator_audit_events) THEN
        RAISE EXCEPTION 'SF-110 rollback refused: operator history exists';
      END IF;
    END;
    $$;
    """)

    drop table(:operator_audit_events)
    drop table(:operator_operations)
    drop table(:operator_ceremonies)
    execute("DROP FUNCTION operator_append_only()")
    drop table(:operator_permission_grants)
    execute("DROP FUNCTION operator_permission_grants_guard()")
    drop table(:operator_step_ups)
    drop table(:operator_webauthn_challenges)
    drop table(:operator_credentials)
    execute("DROP FUNCTION operator_credentials_guard()")
    drop table(:platform_operators)
    execute("DROP FUNCTION platform_operators_guard()")
  end
end
