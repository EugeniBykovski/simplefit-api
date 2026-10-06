defmodule SimpleFit.Repo.Migrations.CreateUsersAndIdentities do
  use Ecto.Migration

  # SF-19: one global user and the identities that sign it in.
  # See docs/architecture/adr/0009-identity-domain.md.
  def change do
    # Deliberately minimal: roles, profiles and workspace memberships are
    # separate records owned by later tickets, never columns on users.
    create table(:users) do
      timestamps()
    end

    create table(:identities) do
      # An identity cannot outlive its user: deleting a user deletes its
      # identities in the same statement.
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Plain text, not a PostgreSQL enum: the supported set is enforced by the
      # domain, so a new provider needs no migration.
      add :provider, :text, null: false
      add :provider_subject, :text, null: false

      timestamps()
    end

    # The canonical identity key, and the lookup path for sign-in.
    create unique_index(:identities, [:provider, :provider_subject])
    # Lists a user's identities and serves the ON DELETE cascade.
    create index(:identities, [:user_id])

    create constraint(:identities, :provider_format, check: "provider ~ '^[a-z][a-z0-9_]{0,31}$'")

    # Opaque, case-sensitive provider subjects: printable ASCII, no spaces.
    create constraint(:identities, :provider_subject_format,
             check:
               "char_length(provider_subject) BETWEEN 1 AND 255 AND provider_subject ~ '^[\\x21-\\x7e]+$'"
           )

    # Email identities are stored only in canonical form (lowercase, one @),
    # so case variants of one address can never become two identities.
    create constraint(:identities, :email_subject_canonical,
             check:
               "provider <> 'email' OR (provider_subject !~ '[A-Z]' AND provider_subject ~ '^[^@]+@[^@]+$')"
           )
  end
end
