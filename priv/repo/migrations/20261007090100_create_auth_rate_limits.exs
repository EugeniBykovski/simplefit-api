defmodule SimpleFit.Repo.Migrations.CreateAuthRateLimits do
  use Ecto.Migration

  # SF-21: fixed-window counters for abuse-sensitive endpoints, shared by
  # every app instance. Keys are HMAC digests: no email or IP is stored.
  # See docs/architecture/adr/0012-passwordless-email-authentication.md.
  def change do
    create table(:auth_rate_limits, primary_key: false) do
      add :bucket, :text, null: false, primary_key: true
      add :key_digest, :binary, null: false, primary_key: true
      add :window_start, :utc_datetime, null: false
      add :count, :integer, null: false
    end

    # Cleanup of stale windows.
    create index(:auth_rate_limits, [:window_start])

    create constraint(:auth_rate_limits, :count_positive, check: "count > 0")

    create constraint(:auth_rate_limits, :key_digest_is_32_bytes,
             check: "octet_length(key_digest) = 32"
           )
  end
end
