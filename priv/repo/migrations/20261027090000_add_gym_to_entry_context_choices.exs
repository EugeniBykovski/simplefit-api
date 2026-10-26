defmodule SimpleFit.Repo.Migrations.AddGymToEntryContextChoices do
  use Ecto.Migration

  # SF-84: the user's last explicit context choice may now name a gym
  # workspace (ADR 0026 D-G15/D-G23, ADR 0017 SF-84 amendment). Still one row
  # per user and still only a navigation preference: the resolver re-validates
  # the gym membership on every read, and every gym operation is authorized by
  # the gym id in its own path. Choosing a gym replaces a profile choice and
  # vice versa. A deleted gym takes the choice with it.
  def up do
    alter table(:entry_context_choices) do
      add :gym_id, references(:gyms, on_delete: :delete_all, type: :binary_id)
    end

    drop constraint(:entry_context_choices, :context_profile_contexts)

    create constraint(:entry_context_choices, :context_values,
             check: "context IN ('fighter', 'coach', 'gym')"
           )

    # A gym choice names its gym; a profile choice names none.
    create constraint(:entry_context_choices, :gym_choice_names_gym,
             check: "(context = 'gym') = (gym_id IS NOT NULL)"
           )

    create index(:entry_context_choices, [:gym_id])
  end

  # Rolling back forgets gym choices (the earlier schema holds profile
  # contexts only); profile choices are kept unchanged.
  def down do
    execute("DELETE FROM entry_context_choices WHERE context = 'gym'")

    drop index(:entry_context_choices, [:gym_id])
    drop constraint(:entry_context_choices, :gym_choice_names_gym)
    drop constraint(:entry_context_choices, :context_values)

    create constraint(:entry_context_choices, :context_profile_contexts,
             check: "context IN ('fighter', 'coach')"
           )

    alter table(:entry_context_choices) do
      remove :gym_id
    end
  end
end
