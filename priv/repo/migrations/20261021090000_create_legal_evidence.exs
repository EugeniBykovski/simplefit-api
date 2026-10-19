defmodule SimpleFit.Repo.Migrations.CreateLegalEvidence do
  use Ecto.Migration

  # SF-72 (ADR 0022): evidence of each fighter's disclosure acceptance and
  # each coach's data-rules acknowledgement. Deliberately without foreign
  # keys: it must survive the deletion of the invitation, relationship,
  # profile or account it names. Append-only: updates are rejected; deletion
  # is left to the retention and erasure work that will own it.
  def change do
    create table(:legal_evidence) do
      add :kind, :text, null: false
      add :subject_user_id, :binary_id, null: false
      add :counterparty_user_id, :binary_id
      add :invitation_id, :binary_id
      add :relationship_id, :binary_id
      add :document_id, :text, null: false
      add :document_version, :text, null: false
      add :document_language, :text, null: false
      add :content_sha256, :text, null: false
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create constraint(:legal_evidence, :kind_values,
             check:
               "kind IN ('fighter_disclosure_acceptance', 'coach_data_rules_acknowledgement')"
           )

    # Each kind names exactly what it proves.
    create constraint(:legal_evidence, :kind_shape,
             check: """
             (kind = 'fighter_disclosure_acceptance' AND
              document_id = 'fighter-coach-disclosure' AND counterparty_user_id IS NOT NULL AND
              invitation_id IS NOT NULL AND relationship_id IS NOT NULL)
             OR
             (kind = 'coach_data_rules_acknowledgement' AND document_id = 'coach-data-rules' AND
              counterparty_user_id IS NULL AND invitation_id IS NULL AND relationship_id IS NULL)
             """
           )

    create constraint(:legal_evidence, :content_sha256_format,
             check: "content_sha256 ~ '^[0-9a-f]{64}$'"
           )

    # No duplicate evidence: one per accepted invitation, one per coach and
    # acknowledged version.
    create unique_index(:legal_evidence, [:invitation_id],
             where: "kind = 'fighter_disclosure_acceptance'",
             name: :legal_evidence_acceptance_index
           )

    create unique_index(:legal_evidence, [:subject_user_id, :document_version],
             where: "kind = 'coach_data_rules_acknowledgement'",
             name: :legal_evidence_acknowledgement_index
           )

    create index(:legal_evidence, [:subject_user_id])

    execute(
      """
      CREATE FUNCTION legal_evidence_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'legal evidence is append-only'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'append_only';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION legal_evidence_append_only()"
    )

    execute(
      """
      CREATE TRIGGER legal_evidence_append_only
      BEFORE UPDATE ON legal_evidence
      FOR EACH ROW EXECUTE FUNCTION legal_evidence_append_only()
      """,
      "DROP TRIGGER legal_evidence_append_only ON legal_evidence"
    )
  end
end
