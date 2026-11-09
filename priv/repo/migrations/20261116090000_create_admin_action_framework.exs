defmodule SimpleFit.Repo.Migrations.CreateAdminActionFramework do
  @moduledoc """
  SF-111: the admin action framework (ADR 0029) on top of SF-110's operator tables.

  * `platform_operators.revision` - the operator's authority state (status and
    permission grants) as a number. A trigger raises it on every update of the row,
    and a trigger on `operator_permission_grants` touches the row on every grant and
    revocation, so the application can't set it and can't forget it. Writes name the
    revision they saw (`expected_revision`).
  * `operator_action_confirmations` - one-time confirmations a preview issues. Only
    the token's SHA-256 is stored, bound to the operator, the session, the action,
    the target, a digest of the canonical parameters and the expected revision. It
    can only be consumed, once.
  * `operator_operations.request_sha256` - the digest of the request an operation id
    was first used for, so the same id with different parameters is refused.
  * `operator_audit_events` - more outcomes (`conflict`, `invalid`, `failed`) and the
    command, result code, state change, resulting revision and confirmation. Still
    append-only (SF-110's trigger), still ids and codes only.

  The triggers bind the application's database role; a database superuser can still
  change any row (D-SA28).
  """

  use Ecto.Migration

  def up do
    alter table(:platform_operators) do
      add :revision, :bigint, null: false, default: 1
    end

    create constraint(:platform_operators, :revision_positive, check: "revision >= 1")

    execute("""
    CREATE FUNCTION platform_operators_revision() RETURNS trigger AS $$
    BEGIN
      NEW.revision := OLD.revision + 1;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    # Runs after platform_operators_guard (triggers fire in name order).
    execute("""
    CREATE TRIGGER platform_operators_revision
      BEFORE UPDATE ON platform_operators
      FOR EACH ROW EXECUTE FUNCTION platform_operators_revision();
    """)

    execute("""
    CREATE FUNCTION operator_permission_grants_touch() RETURNS trigger AS $$
    BEGIN
      UPDATE platform_operators SET revision = revision WHERE id = NEW.operator_id;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER operator_permission_grants_touch
      AFTER INSERT OR UPDATE ON operator_permission_grants
      FOR EACH ROW EXECUTE FUNCTION operator_permission_grants_touch();
    """)

    alter table(:operator_operations) do
      add :request_sha256, :binary
    end

    create table(:operator_action_confirmations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_sha256, :binary, null: false

      add :operator_id, references(:platform_operators, type: :binary_id, on_delete: :restrict),
        null: false

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :action, :text, null: false
      add :target_type, :text, null: false
      add :target_id, :binary_id, null: false
      add :params_sha256, :binary, null: false
      add :expected_revision, :bigint, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:operator_action_confirmations, [:token_sha256])
    create index(:operator_action_confirmations, [:operator_id, :session_id])
    create index(:operator_action_confirmations, [:expires_at])

    create constraint(:operator_action_confirmations, :shape,
             check:
               "action ~ '^[a-z][a-z0-9_.]{1,79}$' AND target_type ~ '^[a-z][a-z0-9_]{1,39}$' AND " <>
                 "octet_length(token_sha256) = 32 AND octet_length(params_sha256) = 32 AND " <>
                 "expected_revision >= 1 AND expires_at > inserted_at"
           )

    execute("""
    CREATE FUNCTION operator_action_confirmations_guard() RETURNS trigger AS $$
    BEGIN
      IF OLD.consumed_at IS NOT NULL OR NEW.consumed_at IS NULL
         OR NEW.token_sha256 <> OLD.token_sha256 OR NEW.operator_id <> OLD.operator_id
         OR NEW.session_id <> OLD.session_id OR NEW.action <> OLD.action
         OR NEW.target_type <> OLD.target_type OR NEW.target_id <> OLD.target_id
         OR NEW.params_sha256 <> OLD.params_sha256
         OR NEW.expected_revision <> OLD.expected_revision
         OR NEW.expires_at <> OLD.expires_at OR NEW.inserted_at <> OLD.inserted_at THEN
        RAISE EXCEPTION 'a confirmation can only be consumed, once'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'operator_action_confirmations_immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER operator_action_confirmations_guard
      BEFORE UPDATE ON operator_action_confirmations
      FOR EACH ROW EXECUTE FUNCTION operator_action_confirmations_guard();
    """)

    alter table(:operator_audit_events) do
      add :command, :text
      add :result_code, :text
      add :from_state, :text
      add :to_state, :text
      add :revision, :bigint
      add :confirmation_id, :binary_id
    end

    drop constraint(:operator_audit_events, :outcome_values)

    create constraint(:operator_audit_events, :outcome_values,
             check: "outcome IN ('allowed', 'refused', 'conflict', 'invalid', 'failed')"
           )

    create constraint(:operator_audit_events, :command_codes,
             check:
               "(command IS NULL OR command ~ '^[a-z][a-z0-9_.]{1,79}$') AND " <>
                 "(result_code IS NULL OR result_code ~ '^[a-z][a-z0-9_]{1,59}$') AND " <>
                 "(from_state IS NULL OR from_state ~ '^[a-z][a-z0-9_]{0,39}$') AND " <>
                 "(to_state IS NULL OR to_state ~ '^[a-z][a-z0-9_]{0,39}$') AND " <>
                 "(revision IS NULL OR revision >= 1)"
           )

    create index(:operator_audit_events, [:occurred_at, :id])
    create index(:operator_audit_events, [:command, :occurred_at])
  end

  def down do
    # Refused once the framework has written anything: audit history isn't destroyed by a rollback.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM operator_audit_events
                 WHERE command IS NOT NULL OR outcome NOT IN ('allowed', 'refused'))
         OR EXISTS (SELECT 1 FROM operator_action_confirmations) THEN
        RAISE EXCEPTION 'SF-111 rollback refused: admin action history exists';
      END IF;
    END;
    $$;
    """)

    drop index(:operator_audit_events, [:command, :occurred_at])
    drop index(:operator_audit_events, [:occurred_at, :id])
    drop constraint(:operator_audit_events, :command_codes)
    drop constraint(:operator_audit_events, :outcome_values)

    create constraint(:operator_audit_events, :outcome_values,
             check: "outcome IN ('allowed', 'refused')"
           )

    alter table(:operator_audit_events) do
      remove :confirmation_id
      remove :revision
      remove :to_state
      remove :from_state
      remove :result_code
      remove :command
    end

    drop table(:operator_action_confirmations)
    execute("DROP FUNCTION operator_action_confirmations_guard()")

    alter table(:operator_operations) do
      remove :request_sha256
    end

    execute("DROP TRIGGER operator_permission_grants_touch ON operator_permission_grants")
    execute("DROP FUNCTION operator_permission_grants_touch()")
    execute("DROP TRIGGER platform_operators_revision ON platform_operators")
    execute("DROP FUNCTION platform_operators_revision()")
    drop constraint(:platform_operators, :revision_positive)

    alter table(:platform_operators) do
      remove :revision
    end
  end
end
