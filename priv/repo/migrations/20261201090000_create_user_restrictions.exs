defmodule SimpleFit.Repo.Migrations.CreateUserRestrictions do
  @moduledoc """
  SF-122 (D-SA29, approved for the MVP by the founder: reversible suspension only):
  operator administration of user accounts.

  * `user_account_states` - one row per user once an operator acted on it: `status`
    (`active` | `suspended`) and a trigger-maintained `revision`, the target of the
    SF-111 admin actions. A user with no row is active at revision 1. `users` gets no
    column (ADR 0009).
  * `user_restrictions` - the suspension history: one row per suspension, lifted at
    most once, never deleted; at most one open suspension per user.
  * Session revocation reasons `operator_revoked` (sign out everywhere) and
    `account_suspended`.
  * Operator permissions `users.read`, `users.reveal_email`, `users.restrict` (SF-107)
    and `users.sessions.revoke` (SF-122). Nothing is granted.

  Rolling back refuses once any of it is in use.
  """

  use Ecto.Migration

  @sf121_permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                        sponsors.applications.claim sponsors.applications.request_changes
                        sponsors.applications.approve sponsors.applications.reject
                        sponsors.applications.read_files sponsors.restrict
                        platform.dashboard.read system.health.read)
  @permissions @sf121_permissions ++
                 ~w(users.read users.reveal_email users.restrict users.sessions.revoke)

  def up do
    create table(:user_account_states, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :status, :text, null: false, default: "active"
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:user_account_states, :status_values,
             check: "status IN ('active', 'suspended')"
           )

    create constraint(:user_account_states, :revision_positive, check: "revision >= 1")

    execute("""
    CREATE FUNCTION user_account_states_revision() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      NEW.revision := OLD.revision + 1;
      RETURN NEW;
    END;
    $$;
    """)

    execute("""
    CREATE TRIGGER user_account_states_revision BEFORE UPDATE ON user_account_states
    FOR EACH ROW EXECUTE FUNCTION user_account_states_revision();
    """)

    create table(:user_restrictions) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :reason_code, :text, null: false
      add :started_at, :utc_datetime_usec, null: false

      add :started_by_operator_id,
          references(:platform_operators, type: :binary_id, on_delete: :restrict),
          null: false

      add :lifted_at, :utc_datetime_usec
      add :lift_reason_code, :text

      add :lifted_by_operator_id,
          references(:platform_operators, type: :binary_id, on_delete: :restrict)
    end

    create constraint(:user_restrictions, :kind_values, check: "kind = 'suspension'")

    create constraint(:user_restrictions, :reason_codes,
             check:
               "reason_code ~ '^[a-z][a-z0-9_]{1,59}$' AND " <>
                 "(lift_reason_code IS NULL OR lift_reason_code ~ '^[a-z][a-z0-9_]{1,59}$')"
           )

    create constraint(:user_restrictions, :lift_complete,
             check:
               "(lifted_at IS NULL AND lift_reason_code IS NULL AND lifted_by_operator_id IS NULL) OR " <>
                 "(lifted_at IS NOT NULL AND lift_reason_code IS NOT NULL AND lifted_by_operator_id IS NOT NULL)"
           )

    create index(:user_restrictions, [:user_id, :started_at])

    create unique_index(:user_restrictions, [:user_id],
             where: "lifted_at IS NULL",
             name: :user_restrictions_one_open_index
           )

    execute("""
    CREATE FUNCTION user_restrictions_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF NOT EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
          RETURN OLD; -- the user's own deletion cascades
        END IF;
        RAISE EXCEPTION 'user restrictions are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'user_restrictions_no_delete';
      END IF;
      IF NEW.user_id <> OLD.user_id OR NEW.kind <> OLD.kind OR NEW.reason_code <> OLD.reason_code
         OR NEW.started_at <> OLD.started_at OR NEW.started_by_operator_id <> OLD.started_by_operator_id
         OR OLD.lifted_at IS NOT NULL THEN
        RAISE EXCEPTION 'a restriction can only be lifted, once'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'user_restrictions_lift_once';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    execute("""
    CREATE TRIGGER user_restrictions_guard BEFORE UPDATE OR DELETE ON user_restrictions
    FOR EACH ROW EXECUTE FUNCTION user_restrictions_guard();
    """)

    revocation_reasons(~w(logout refresh_reuse operator_revoked account_suspended))
    permissions(@permissions)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM user_restrictions)
         OR EXISTS (SELECT 1 FROM sessions
                    WHERE revoked_reason IN ('operator_revoked', 'account_suspended'))
         OR EXISTS (SELECT 1 FROM operator_permission_grants
                    WHERE permission IN ('users.read', 'users.reveal_email', 'users.restrict',
                                         'users.sessions.revoke')) THEN
        RAISE EXCEPTION 'SF-122 rollback refused: user administration was used';
      END IF;
    END
    $$;
    """)

    permissions(@sf121_permissions)
    revocation_reasons(~w(logout refresh_reuse))
    execute("DROP TRIGGER user_restrictions_guard ON user_restrictions")
    execute("DROP FUNCTION user_restrictions_guard()")
    drop table(:user_restrictions)
    execute("DROP TRIGGER user_account_states_revision ON user_account_states")
    execute("DROP FUNCTION user_account_states_revision()")
    drop table(:user_account_states)
  end

  defp permissions(list) do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{quoted(list)})"
           )
  end

  defp revocation_reasons(list) do
    drop constraint(:sessions, :revocation_consistent)

    create constraint(:sessions, :revocation_consistent,
             check:
               "(revoked_at IS NULL AND revoked_reason IS NULL) OR " <>
                 "(revoked_at IS NOT NULL AND revoked_reason IS NOT NULL AND " <>
                 "revoked_reason IN (#{quoted(list)}))"
           )
  end

  defp quoted(list), do: Enum.map_join(list, ", ", &"'#{&1}'")
end
