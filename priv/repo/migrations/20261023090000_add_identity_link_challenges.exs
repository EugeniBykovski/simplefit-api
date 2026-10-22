defmodule SimpleFit.Repo.Migrations.AddIdentityLinkChallenges do
  use Ecto.Migration

  # SF-77: a third email challenge purpose, `identity_link`: a signed-in user
  # proves control of an address before it becomes an email identity of that
  # same user. See docs/architecture/adr/0024-email-identity-linking.md.
  #
  # A link challenge is bound to the user and the session that requested it:
  # deleting either deletes the challenge, so a stale one can never link.
  def up do
    alter table(:email_auth_challenges) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :session_id, references(:sessions, on_delete: :delete_all)
    end

    # Serve the ON DELETE cascades.
    create index(:email_auth_challenges, [:user_id], where: "user_id IS NOT NULL")
    create index(:email_auth_challenges, [:session_id], where: "session_id IS NOT NULL")

    # Registration and sign-in keep one open challenge per address. A link
    # challenge is per user instead: a new request (for any address)
    # supersedes the user's open one, and two users can never supersede each
    # other's challenge for the same address.
    drop index(:email_auth_challenges, [:purpose, :target_digest],
           name: :email_auth_challenges_one_open_index
         )

    create unique_index(:email_auth_challenges, [:purpose, :target_digest],
             where: "closed_at IS NULL AND purpose <> 'identity_link'",
             name: :email_auth_challenges_one_open_index
           )

    create unique_index(:email_auth_challenges, [:user_id],
             where: "closed_at IS NULL AND purpose = 'identity_link'",
             name: :email_auth_challenges_one_open_link_index
           )

    # The latest link challenge of a user (confirmation).
    create index(:email_auth_challenges, [:user_id, :inserted_at],
             where: "purpose = 'identity_link'",
             name: :email_auth_challenges_link_latest_index
           )

    drop constraint(:email_auth_challenges, :purpose_known)

    create constraint(:email_auth_challenges, :purpose_known,
             check: "purpose IN ('verification', 'sign_in', 'identity_link')"
           )

    drop constraint(:email_auth_challenges, :purpose_fields)

    # Link challenges carry the address, the user and the session, never the
    # registration tokens, and never issue a session.
    create constraint(:email_auth_challenges, :purpose_fields,
             check:
               "(purpose = 'verification' AND email IS NOT NULL AND " <>
                 "link_token_hash IS NOT NULL AND registration_token_hash IS NOT NULL AND " <>
                 "user_id IS NULL AND session_id IS NULL) OR " <>
                 "(purpose = 'sign_in' AND email IS NULL AND " <>
                 "link_token_hash IS NULL AND registration_token_hash IS NULL AND " <>
                 "user_id IS NULL AND session_id IS NULL) OR " <>
                 "(purpose = 'identity_link' AND email IS NOT NULL AND " <>
                 "link_token_hash IS NULL AND registration_token_hash IS NULL AND " <>
                 "user_id IS NOT NULL AND session_id IS NOT NULL AND session_created_at IS NULL)"
           )
  end

  def down do
    execute "DELETE FROM email_auth_challenges WHERE purpose = 'identity_link'"

    drop constraint(:email_auth_challenges, :purpose_fields)

    create constraint(:email_auth_challenges, :purpose_fields,
             check:
               "(purpose = 'verification' AND email IS NOT NULL AND " <>
                 "link_token_hash IS NOT NULL AND registration_token_hash IS NOT NULL) OR " <>
                 "(purpose = 'sign_in' AND email IS NULL AND " <>
                 "link_token_hash IS NULL AND registration_token_hash IS NULL)"
           )

    drop constraint(:email_auth_challenges, :purpose_known)

    create constraint(:email_auth_challenges, :purpose_known,
             check: "purpose IN ('verification', 'sign_in')"
           )

    drop index(:email_auth_challenges, [:user_id, :inserted_at],
           name: :email_auth_challenges_link_latest_index
         )

    drop index(:email_auth_challenges, [:user_id],
           name: :email_auth_challenges_one_open_link_index
         )

    drop index(:email_auth_challenges, [:purpose, :target_digest],
           name: :email_auth_challenges_one_open_index
         )

    create unique_index(:email_auth_challenges, [:purpose, :target_digest],
             where: "closed_at IS NULL",
             name: :email_auth_challenges_one_open_index
           )

    drop index(:email_auth_challenges, [:session_id], where: "session_id IS NOT NULL")
    drop index(:email_auth_challenges, [:user_id], where: "user_id IS NOT NULL")

    alter table(:email_auth_challenges) do
      remove :session_id
      remove :user_id
    end
  end
end
