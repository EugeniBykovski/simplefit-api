defmodule SimpleFit.Repo.Migrations.CreateCoachInvitations do
  use Ecto.Migration

  # SF-57: coach invitations and the coach data-rules acknowledgement
  # (ADR 0021 amendment; SF-49 §6.3, §7). An invitation is never a
  # relationship: only a fighter's acceptance creates one, through the
  # trusted activation of SF-56, in the same transaction that consumes the
  # invitation.
  def change do
    create table(:coach_invitations) do
      add :coach_profile_id, references(:coach_profiles, on_delete: :delete_all), null: false

      # The one-time token is never stored: only its SHA-256 (32 bytes). A
      # resend replaces it, so an older token stops matching.
      add :token_hash, :binary, null: false

      # The recipient address is never stored in plain text: an HMAC digest of
      # the canonical address (recipient binding, duplicates, limits) and an
      # encrypted copy (resend, masked display to the inviting coach).
      add :recipient_digest, :binary, null: false
      add :recipient_sealed, :text, null: false

      # The coach's optional note (plain text, shown escaped).
      add :message, :text

      add :status, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false

      # Deliveries (the first send and each resend) and the last one.
      add :send_count, :integer, null: false, default: 1
      add :last_sent_at, :utc_datetime_usec, null: false

      # The outcome: when the invitation was accepted, declined or cancelled;
      # for an acceptance, the disclosure version the fighter accepted (the
      # consent evidence) and the relationship it resolved to.
      add :responded_at, :utc_datetime_usec
      add :accepted_disclosure_version, :text

      add :relationship_id,
          references(:coach_fighter_relationships, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coach_invitations, [:token_hash])

    # One pending invitation per coach and recipient; the history is free.
    create unique_index(:coach_invitations, [:coach_profile_id, :recipient_digest],
             where: "status = 'pending'",
             name: :coach_invitations_pending_recipient_index
           )

    create index(:coach_invitations, [:coach_profile_id, :status, :inserted_at])

    create constraint(:coach_invitations, :status_values,
             check: "status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')"
           )

    create constraint(:coach_invitations, :digest_sizes,
             check: "octet_length(token_hash) = 32 AND octet_length(recipient_digest) = 32"
           )

    create constraint(:coach_invitations, :message_length,
             check: "message IS NULL OR char_length(message) BETWEEN 1 AND 500"
           )

    create constraint(:coach_invitations, :send_count_range, check: "send_count >= 1")

    # Only an acceptance carries consent evidence; only a response carries a
    # response time; a pending or expired invitation carries neither.
    create constraint(:coach_invitations, :outcome_shape,
             check: """
             (status IN ('pending', 'expired') AND responded_at IS NULL AND
              accepted_disclosure_version IS NULL AND relationship_id IS NULL)
             OR
             (status = 'accepted' AND responded_at IS NOT NULL AND
              accepted_disclosure_version IS NOT NULL)
             OR
             (status IN ('declined', 'cancelled') AND responded_at IS NOT NULL AND
              accepted_disclosure_version IS NULL AND relationship_id IS NULL)
             """
           )

    # A terminal invitation never changes again (it never becomes pending, and
    # its outcome is never rewritten). The one exception is the database
    # itself clearing relationship_id when that relationship's profiles are
    # deleted. A pending invitation keeps its coach, recipient and creation.
    execute(
      """
      CREATE FUNCTION coach_invitations_transition_guard() RETURNS trigger AS $$
      BEGIN
        IF OLD.status <> 'pending' THEN
          IF NEW.relationship_id IS NULL AND OLD.relationship_id IS NOT NULL AND
             (to_jsonb(NEW) - 'relationship_id' - 'updated_at') =
             (to_jsonb(OLD) - 'relationship_id' - 'updated_at') THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'a resolved invitation is immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'resolved_immutable';
        END IF;

        IF NEW.coach_profile_id IS DISTINCT FROM OLD.coach_profile_id OR
           NEW.recipient_digest IS DISTINCT FROM OLD.recipient_digest OR
           NEW.recipient_sealed IS DISTINCT FROM OLD.recipient_sealed OR
           NEW.message IS DISTINCT FROM OLD.message OR
           NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
          RAISE EXCEPTION 'an invitation keeps its coach, recipient and message'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'invitation_identity';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION coach_invitations_transition_guard()"
    )

    execute(
      """
      CREATE TRIGGER coach_invitations_transition_guard
      BEFORE UPDATE ON coach_invitations
      FOR EACH ROW EXECUTE FUNCTION coach_invitations_transition_guard()
      """,
      "DROP TRIGGER coach_invitations_transition_guard ON coach_invitations"
    )

    # The coach's acknowledgement of a version of the coach data rules
    # (SF-49 §7.4): separate from account consents and from the coach
    # profile. Append-only; one row per version.
    create table(:coach_data_rules_acknowledgements) do
      add :coach_profile_id, references(:coach_profiles, on_delete: :delete_all), null: false
      add :document_version, :text, null: false
      add :acknowledged_at, :utc_datetime_usec, null: false
    end

    create unique_index(:coach_data_rules_acknowledgements, [
             :coach_profile_id,
             :document_version
           ])

    create constraint(:coach_data_rules_acknowledgements, :document_version_length,
             check: "char_length(document_version) BETWEEN 1 AND 64"
           )

    execute(
      """
      CREATE FUNCTION coach_data_rules_acknowledgements_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'acknowledgements are append-only'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'append_only';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION coach_data_rules_acknowledgements_append_only()"
    )

    execute(
      """
      CREATE TRIGGER coach_data_rules_acknowledgements_append_only
      BEFORE UPDATE ON coach_data_rules_acknowledgements
      FOR EACH ROW EXECUTE FUNCTION coach_data_rules_acknowledgements_append_only()
      """,
      "DROP TRIGGER coach_data_rules_acknowledgements_append_only ON coach_data_rules_acknowledgements"
    )
  end
end
