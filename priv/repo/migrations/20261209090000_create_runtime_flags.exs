defmodule SimpleFit.Repo.Migrations.CreateRuntimeFlags do
  @moduledoc """
  SF-128: runtime suspension of deployment-enabled features (D-SA35).

  * Operator permissions `config.read` (the configuration inventory and history) and
    `config.flags.write` (suspend or restore an allowlisted feature). Nothing is granted.
  * `runtime_flags` - one row per allowlisted feature (the key list is a check
    constraint, so no other key can exist): `suspended` and a `revision` the trigger
    raises on every change. A suspension can only turn a feature off: the deployment's
    environment variable still decides whether it can be on at all.
  * `runtime_flag_revisions` - the append-only history: every change with its
    previous and new state, operator, reason and operation id. Never updated or
    deleted.

  Rolling back refuses while history exists or either permission is granted.
  """

  use Ecto.Migration

  @keys ~w(gym.member_invitations gym.staff_invitations sponsor.application_emails
           sponsor.evidence_uploads)

  @sf127_permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                        sponsors.applications.claim sponsors.applications.request_changes
                        sponsors.applications.approve sponsors.applications.reject
                        sponsors.applications.read_files sponsors.restrict
                        platform.dashboard.read system.health.read
                        users.read users.reveal_email users.restrict users.sessions.revoke
                        gyms.read coaches.read fighters.read system.jobs.read
                        billing.read billing.reconciliation.read)

  def up do
    permissions(@sf127_permissions ++ ["config.read", "config.flags.write"])

    create table(:runtime_flags) do
      add :key, :text, null: false
      add :suspended, :boolean, null: false, default: false
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runtime_flags, [:key])
    create constraint(:runtime_flags, :key_allowlist, check: "key IN (#{quoted(@keys)})")
    create constraint(:runtime_flags, :revision_positive, check: "revision > 0")

    execute("""
    CREATE FUNCTION runtime_flags_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'runtime flags are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'runtime_flags_no_delete';
      END IF;
      IF NEW.key <> OLD.key THEN
        RAISE EXCEPTION 'a runtime flag''s key is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'runtime_flags_immutable_key';
      END IF;
      IF NEW.suspended IS DISTINCT FROM OLD.suspended THEN
        NEW.revision := OLD.revision + 1;
      ELSE
        NEW.revision := OLD.revision;
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER runtime_flags_guard BEFORE UPDATE OR DELETE ON runtime_flags
    FOR EACH ROW EXECUTE FUNCTION runtime_flags_guard()
    """)

    execute("""
    INSERT INTO runtime_flags (id, key, suspended, revision, inserted_at, updated_at)
    SELECT gen_random_uuid(), k, false, 1, now(), now() FROM unnest(ARRAY[#{quoted(@keys)}]) AS k
    """)

    create table(:runtime_flag_revisions) do
      add :flag_id, references(:runtime_flags, on_delete: :nothing), null: false
      add :revision, :integer, null: false
      add :change, :text, null: false
      add :suspended, :boolean, null: false
      add :previous_suspended, :boolean, null: false
      add :operator_id, references(:platform_operators, on_delete: :nothing), null: false
      add :reason_code, :text, null: false
      add :operation_id, :binary_id, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:runtime_flag_revisions, [:flag_id, :revision])
    create index(:runtime_flag_revisions, [:flag_id, :inserted_at])

    create constraint(:runtime_flag_revisions, :change_values,
             check:
               "(change = 'suspend' AND suspended AND NOT previous_suspended) OR " <>
                 "(change = 'restore' AND NOT suspended AND previous_suspended)"
           )

    execute("""
    CREATE FUNCTION runtime_flag_revisions_guard() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'runtime flag history is append-only'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'runtime_flag_revisions_append_only';
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER runtime_flag_revisions_guard BEFORE UPDATE OR DELETE ON runtime_flag_revisions
    FOR EACH ROW EXECUTE FUNCTION runtime_flag_revisions_guard()
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM runtime_flag_revisions) THEN
        RAISE EXCEPTION 'SF-128 rollback refused: runtime flag history exists';
      END IF;
    END
    $$
    """)

    drop table(:runtime_flag_revisions)
    execute("DROP FUNCTION runtime_flag_revisions_guard()")
    execute("DROP TRIGGER runtime_flags_guard ON runtime_flags")
    drop table(:runtime_flags)
    execute("DROP FUNCTION runtime_flags_guard()")
    permissions(@sf127_permissions)
  end

  defp permissions(list) do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{quoted(list)})"
           )
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
