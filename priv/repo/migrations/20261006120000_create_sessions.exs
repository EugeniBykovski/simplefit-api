defmodule SimpleFit.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  # SF-20: SimpleFit-owned sessions. See docs/architecture/adr/0010-sessions.md.
  def change do
    create table(:sessions) do
      # A session cannot outlive its user.
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Absolute end of the session: no refresh can extend it.
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :revoked_reason, :text

      timestamps()
    end

    # Serves the ON DELETE cascade and a future "sign out everywhere".
    create index(:sessions, [:user_id])

    create constraint(:sessions, :revocation_consistent,
             check:
               "(revoked_at IS NULL AND revoked_reason IS NULL) OR " <>
                 "(revoked_at IS NOT NULL AND revoked_reason IS NOT NULL AND " <>
                 "revoked_reason IN ('logout', 'refresh_reuse'))"
           )

    create constraint(:sessions, :expires_after_creation, check: "expires_at > inserted_at")

    # Every refresh token a session was issued. Only the SHA-256 of the
    # secret is stored. Consumed rows are kept so that a replayed token is
    # recognised (and revokes its session) instead of looking unknown.
    create table(:session_refresh_tokens) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(updated_at: false)
    end

    # The refresh lookup path.
    create unique_index(:session_refresh_tokens, [:token_hash])
    # At most one usable refresh token per session: two concurrent rotations
    # can never leave two live successors.
    create unique_index(:session_refresh_tokens, [:session_id],
             where: "consumed_at IS NULL",
             name: :session_refresh_tokens_one_active_index
           )

    # Serves the ON DELETE cascade from sessions.
    create index(:session_refresh_tokens, [:session_id])

    create constraint(:session_refresh_tokens, :token_hash_is_sha256,
             check: "octet_length(token_hash) = 32"
           )
  end
end
