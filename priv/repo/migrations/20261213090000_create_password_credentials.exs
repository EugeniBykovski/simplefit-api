defmodule SimpleFit.Repo.Migrations.CreatePasswordCredentials do
  @moduledoc """
  SF-157 (ADR 0012 and ADR 0028 amendments, approved by the founder): an optional
  password credential for a user that has an email identity.

  * `password_credentials` - at most one per user: an Argon2id hash, never the
    password. `users` gets no column (ADR 0009). Deleting the user deletes it.
  * `account_security_events` - an append-only record of password set, change and
    reset (no address, no password, no IP). Rows go only with their user.
  * Email challenge purpose `password_reset`: shaped like `sign_in` (digest only,
    no address, no tokens, no user or session), with its own code verifier.
  * Session revocation reason `password_changed`.

  Rolling back refuses once a password was ever set.
  """

  use Ecto.Migration

  def up do
    create table(:password_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :password_hash, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:password_credentials, [:user_id])

    create constraint(:password_credentials, :argon2id_hash,
             check: "password_hash LIKE '$argon2id$%'"
           )

    create table(:account_security_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :event, :text, null: false
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:account_security_events, [:user_id, :occurred_at])
    create index(:account_security_events, [:session_id], where: "session_id IS NOT NULL")

    create constraint(:account_security_events, :event_known,
             check: "event IN ('password_set', 'password_changed', 'password_reset')"
           )

    # Append-only: only the ON DELETE SET NULL of a deleted session may touch a row.
    execute("""
    CREATE FUNCTION account_security_events_guard() RETURNS trigger AS $$
    BEGIN
      IF NEW.id IS DISTINCT FROM OLD.id
         OR NEW.user_id IS DISTINCT FROM OLD.user_id
         OR NEW.event IS DISTINCT FROM OLD.event
         OR NEW.occurred_at IS DISTINCT FROM OLD.occurred_at
         OR NEW.session_id IS NOT NULL THEN
        RAISE EXCEPTION 'account_security_events are append-only';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER account_security_events_guard BEFORE UPDATE ON account_security_events
    FOR EACH ROW EXECUTE FUNCTION account_security_events_guard();
    """)

    purposes(~w(verification sign_in identity_link password_reset))

    revocation_reasons(
      ~w(logout refresh_reuse operator_revoked account_suspended password_changed)
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM password_credentials)
         OR EXISTS (SELECT 1 FROM account_security_events)
         OR EXISTS (SELECT 1 FROM sessions WHERE revoked_reason = 'password_changed') THEN
        RAISE EXCEPTION 'SF-157 rollback refused: passwords were used';
      END IF;
    END
    $$;
    """)

    execute("DELETE FROM email_auth_challenges WHERE purpose = 'password_reset'")
    revocation_reasons(~w(logout refresh_reuse operator_revoked account_suspended))
    purposes(~w(verification sign_in identity_link))
    execute("DROP TRIGGER account_security_events_guard ON account_security_events")
    execute("DROP FUNCTION account_security_events_guard()")
    drop table(:account_security_events)
    drop table(:password_credentials)
  end

  defp purposes(list) do
    drop constraint(:email_auth_challenges, :purpose_known)

    create constraint(:email_auth_challenges, :purpose_known,
             check: "purpose IN (#{quoted(list)})"
           )

    drop constraint(:email_auth_challenges, :purpose_fields)

    # A password reset challenge has the shape of a sign-in challenge.
    create constraint(:email_auth_challenges, :purpose_fields,
             check:
               "(purpose = 'verification' AND email IS NOT NULL AND " <>
                 "link_token_hash IS NOT NULL AND registration_token_hash IS NOT NULL AND " <>
                 "user_id IS NULL AND session_id IS NULL) OR " <>
                 "(purpose IN ('sign_in', 'password_reset') AND email IS NULL AND " <>
                 "link_token_hash IS NULL AND registration_token_hash IS NULL AND " <>
                 "user_id IS NULL AND session_id IS NULL) OR " <>
                 "(purpose = 'identity_link' AND email IS NOT NULL AND " <>
                 "link_token_hash IS NULL AND registration_token_hash IS NULL AND " <>
                 "user_id IS NOT NULL AND session_id IS NOT NULL AND session_created_at IS NULL)"
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
