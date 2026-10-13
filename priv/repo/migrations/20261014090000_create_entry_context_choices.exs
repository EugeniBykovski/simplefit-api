defmodule SimpleFit.Repo.Migrations.CreateEntryContextChoices do
  use Ecto.Migration

  # SF-51: the user's last explicitly chosen application context (Fighter or
  # Coach), owned by SimpleFit.Entry (ADR 0017 amendment, SF-49 §5). A
  # navigation preference, never an authorization grant: the resolver
  # re-validates it against completed profiles on every read.
  def change do
    create table(:entry_context_choices, primary_key: false) do
      # One choice per user; it cannot outlive the user.
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id),
        primary_key: true

      add :context, :text, null: false
      add :chosen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Profile contexts only. Gym or sponsor workspaces are organizations,
    # chosen by their own domains, never stored here.
    create constraint(:entry_context_choices, :context_profile_contexts,
             check: "context IN ('fighter', 'coach')"
           )
  end
end
