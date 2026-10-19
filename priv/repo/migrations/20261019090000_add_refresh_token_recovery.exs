defmodule SimpleFit.Repo.Migrations.AddRefreshTokenRecovery do
  use Ecto.Migration

  # SF-75: lost-response recovery for refresh rotation (ADR 0010, "Reuse").
  # A consumed token may be presented again only while none of its children
  # has ever been presented; that needs the token chain (`parent_id`), the
  # mark of a child replaced before its first use (`superseded_at`) and a
  # bound on recoveries per token. Existing rows keep NULL / 0: tokens issued
  # before this migration have no known parent, so they rotate strictly.
  def change do
    alter table(:session_refresh_tokens) do
      # The token whose presentation issued this one; NULL for a session's
      # first token. Deleting a token (only ever with its session) drops its
      # children too.
      add :parent_id, references(:session_refresh_tokens, on_delete: :delete_all)
      add :superseded_at, :utc_datetime
      add :recoveries, :smallint, null: false, default: 0
    end

    # The recovery check reads the children of a token.
    create index(:session_refresh_tokens, [:parent_id])

    create constraint(:session_refresh_tokens, :superseded_is_consumed,
             check: "superseded_at IS NULL OR consumed_at IS NOT NULL"
           )

    create constraint(:session_refresh_tokens, :recoveries_bounded,
             check: "recoveries >= 0 AND recoveries <= 100"
           )
  end
end
