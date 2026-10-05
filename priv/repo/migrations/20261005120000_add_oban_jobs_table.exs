defmodule SimpleFit.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  # Oban's own schema (oban_jobs, oban_peers and functions). Pinned to version
  # 14 so the migration is deterministic; a future Oban upgrade that needs a
  # newer schema adds a new migration calling up(version: N).
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end
