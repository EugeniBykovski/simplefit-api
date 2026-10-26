defmodule SimpleFit.Repo.Migrations.CreateRateLimitEvents do
  use Ecto.Migration

  # SF-83: exact rolling-window limits (SimpleFit.RateLimit.hit_rolling/2,
  # D-G25). One row per counted event, keyed like auth_rate_limits by an HMAC
  # digest (no email or IP is stored), removed by the hourly cleanup once
  # older than every rolling period.
  def change do
    create table(:rate_limit_events) do
      add :bucket, :text, null: false
      add :key_digest, :binary, null: false
      add :occurred_at, :utc_datetime_usec, null: false
    end

    # Counting one key's window, and the cleanup by age.
    create index(:rate_limit_events, [:bucket, :key_digest, :occurred_at])
    create index(:rate_limit_events, [:occurred_at])

    create constraint(:rate_limit_events, :key_digest_is_32_bytes,
             check: "octet_length(key_digest) = 32"
           )
  end
end
