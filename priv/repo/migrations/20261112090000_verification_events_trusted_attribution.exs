defmodule SimpleFit.Repo.Migrations.VerificationEventsTrustedAttribution do
  @moduledoc """
  SF-136: operator history names an immutable actor from an authority, never an
  email address.

  Existing rows keep their `operator` address untouched: it was typed by whoever
  ran the task, so it is legacy, unverified attribution. A row with an `operator`
  and no `operator_authority` is exactly that. Rewriting them would pretend they
  were authenticated.

  `gym_verification_events_trusted_actor` is `NOT VALID` on purpose: it binds every
  new row and leaves the history unchecked (the table is append-only, so old rows
  are never re-evaluated). It must never be validated.
  """

  use Ecto.Migration

  def up do
    alter table(:gym_verification_events) do
      add :operator_actor_id, :binary_id
      add :operator_authority, :text
      add :operation_id, :binary_id
    end

    drop constraint(:gym_verification_events, :actor)

    # Legacy rows carry `operator`; new operator rows carry the actor id instead.
    create constraint(:gym_verification_events, :actor,
             check:
               "(event = 'submitted' AND actor_user_id IS NOT NULL AND operator IS NULL " <>
                 "AND operator_actor_id IS NULL) OR " <>
                 "(event <> 'submitted' AND actor_user_id IS NULL AND (" <>
                 "(operator IS NOT NULL AND char_length(operator) BETWEEN 3 AND 254 " <>
                 "AND operator_actor_id IS NULL AND operator_authority IS NULL) OR " <>
                 "(operator IS NULL AND operator_actor_id IS NOT NULL " <>
                 "AND operator_authority IS NOT NULL)))"
           )

    # Adding a real authority (SF-110) means a new value here, in a reviewed migration.
    create constraint(:gym_verification_events, :operator_authority_values,
             check: "operator_authority IS NULL OR operator_authority IN ('local_fixture')"
           )

    execute("""
    ALTER TABLE gym_verification_events
    ADD CONSTRAINT gym_verification_events_trusted_actor
    CHECK (event = 'submitted' OR (operator IS NULL AND operator_actor_id IS NOT NULL
      AND operator_authority IS NOT NULL AND operation_id IS NOT NULL))
    NOT VALID
    """)
  end

  # Fails if any row holds the new attribution: those rows can't be expressed in the
  # old shape, and history is not rewritten to make a rollback pass.
  def down do
    execute(
      "ALTER TABLE gym_verification_events DROP CONSTRAINT gym_verification_events_trusted_actor"
    )

    drop constraint(:gym_verification_events, :operator_authority_values)
    drop constraint(:gym_verification_events, :actor)

    create constraint(:gym_verification_events, :actor,
             check:
               "(event = 'submitted' AND actor_user_id IS NOT NULL AND operator IS NULL) OR " <>
                 "(event <> 'submitted' AND actor_user_id IS NULL AND operator IS NOT NULL " <>
                 "AND char_length(operator) BETWEEN 3 AND 254)"
           )

    alter table(:gym_verification_events) do
      remove :operation_id
      remove :operator_authority
      remove :operator_actor_id
    end
  end
end
