defmodule SimpleFit.Repo.Migrations.CreateEmailAuthChallenges do
  use Ecto.Migration

  # SF-21: passwordless email authentication challenges.
  # See docs/architecture/adr/0012-passwordless-email-authentication.md.
  def change do
    create table(:email_auth_challenges) do
      # 'verification' (email ownership, E01) or 'sign_in' (E17).
      add :purpose, :text, null: false
      # HMAC-SHA256 of the canonical email under a dedicated key: the target
      # of both purposes, never the raw address.
      add :target_digest, :binary, null: false
      # Verification only: the canonical address the verified identity will
      # use. Sign-in challenges never store an email.
      add :email, :text
      # Keyed verifier of the 6-digit code (never the code itself).
      add :code_hash, :binary, null: false
      # Verification only: SHA-256 of the E01 link token and of the
      # registration continuation token held by the device that started it.
      add :link_token_hash, :binary
      add :registration_token_hash, :binary
      add :failed_attempts, :smallint, null: false, default: 0
      add :expires_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :closed_reason, :text
      # When the one SF-20 session of a code-verified challenge was issued.
      add :session_created_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # At most one open challenge per purpose and target: a new request
    # supersedes the old one in the same transaction.
    create unique_index(:email_auth_challenges, [:purpose, :target_digest],
             where: "closed_at IS NULL",
             name: :email_auth_challenges_one_open_index
           )

    # Lookup paths of the high-entropy tokens.
    create unique_index(:email_auth_challenges, [:link_token_hash])
    create unique_index(:email_auth_challenges, [:registration_token_hash])

    # Latest challenge of a target (sign-in verification) and cleanup.
    create index(:email_auth_challenges, [:purpose, :target_digest, :inserted_at])
    create index(:email_auth_challenges, [:expires_at])

    create constraint(:email_auth_challenges, :purpose_known,
             check: "purpose IN ('verification', 'sign_in')"
           )

    # Verification challenges carry the email and both tokens; sign-in
    # challenges carry none of them.
    create constraint(:email_auth_challenges, :purpose_fields,
             check:
               "(purpose = 'verification' AND email IS NOT NULL AND " <>
                 "link_token_hash IS NOT NULL AND registration_token_hash IS NOT NULL) OR " <>
                 "(purpose = 'sign_in' AND email IS NULL AND " <>
                 "link_token_hash IS NULL AND registration_token_hash IS NULL)"
           )

    create constraint(:email_auth_challenges, :verifiers_are_32_bytes,
             check:
               "octet_length(target_digest) = 32 AND octet_length(code_hash) = 32 AND " <>
                 "(link_token_hash IS NULL OR octet_length(link_token_hash) = 32) AND " <>
                 "(registration_token_hash IS NULL OR octet_length(registration_token_hash) = 32)"
           )

    create constraint(:email_auth_challenges, :failed_attempts_range,
             check: "failed_attempts BETWEEN 0 AND 5"
           )

    create constraint(:email_auth_challenges, :expires_after_creation,
             check: "expires_at > inserted_at"
           )

    # Closed together with a known reason; only verification challenges can
    # be verified through the E01 link.
    create constraint(:email_auth_challenges, :closed_consistent,
             check:
               "(closed_at IS NULL AND closed_reason IS NULL) OR " <>
                 "(closed_at IS NOT NULL AND closed_reason IN " <>
                 "('code_verified', 'link_verified', 'superseded', 'exhausted', 'conflict') AND " <>
                 "(closed_reason <> 'link_verified' OR purpose = 'verification'))"
           )

    # A session is only ever issued for a challenge whose code was entered by
    # the requesting client: a link-verified challenge can never produce one.
    create constraint(:email_auth_challenges, :session_only_after_code,
             check: "session_created_at IS NULL OR closed_reason = 'code_verified'"
           )
  end
end
