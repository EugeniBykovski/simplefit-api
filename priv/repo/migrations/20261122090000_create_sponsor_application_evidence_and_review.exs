defmodule SimpleFit.Repo.Migrations.CreateSponsorApplicationEvidenceAndReview do
  @moduledoc """
  SF-114: sponsor application evidence, change requests, contact verification and
  notifications (ADR 0032).

  * `sponsor_application_evidence` - private uploads under a key the server built
    (`sponsors/applications/<application>/evidence/<evidence>`): `pending_upload`
    until the server read the object's size and type with a HEAD and found what it
    allowed, then `uploaded`; `removed` (by the owner, or abandoned by cleanup;
    replacing a document is removing it and uploading another). Once part of a submission (`submission_id`) a document is frozen.
    Never scanned for malware (no scanner exists, D-SA09). Never deleted as rows.
  * `sponsor_application_change_requests` - an operator's request for changes:
    reason code, the requested answers and a plain-text message to the applicant.
    Resolved by the next submission. Append-only except resolution.
  * `sponsor_application_contact_codes` - one-time codes sent to the contact email:
    stored as keyed verifiers with the address digest they were sent to, expiring,
    with an attempt count. The application records the verified digest; changing
    the contact email voids it.
  * `sponsor_application_notifications` - one row per notification intent (event,
    recipient kind, dedupe key, queued or suppressed). Ids and codes only.
  * Operator permissions `sponsors.applications.read`, `.claim`, `.request_changes`.
  """

  use Ecto.Migration

  @old_permissions ~w(operators.read operators.manage audit.read)
  @permissions @old_permissions ++
                 ~w(sponsors.applications.read sponsors.applications.claim sponsors.applications.request_changes)

  defp list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  def up do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{list(@permissions)})"
           )

    alter table(:sponsor_applications) do
      add :contact_email_verified_digest, :binary
      add :contact_email_verified_at, :utc_datetime_usec
    end

    create constraint(:sponsor_applications, :contact_verification,
             check:
               "(contact_email_verified_digest IS NULL) = (contact_email_verified_at IS NULL)"
           )

    create table(:sponsor_application_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:sponsor_applications, type: :binary_id, on_delete: :restrict),
          null: false

      add :kind, :text, null: false
      add :status, :text, null: false
      add :object_key, :text, null: false
      add :content_type, :text, null: false
      add :byte_size, :bigint, null: false
      add :file_name, :text, null: false
      add :created_by_user_id, :binary_id, null: false
      add :upload_expires_at, :utc_datetime_usec, null: false
      add :uploaded_at, :utc_datetime_usec
      add :removed_at, :utc_datetime_usec
      add :removed_reason, :text

      add :submission_id,
          references(:sponsor_application_submissions, type: :binary_id, on_delete: :restrict)

      add :object_deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:sponsor_application_evidence, :shape,
             check:
               "kind IN ('logo', 'brand_deck', 'campaign_brief', 'other') AND " <>
                 "status IN ('pending_upload', 'uploaded', 'removed') AND " <>
                 "content_type IN ('application/pdf', 'image/jpeg', 'image/png') AND " <>
                 "byte_size BETWEEN 1 AND 10485760 AND " <>
                 "char_length(file_name) BETWEEN 1 AND 120 AND " <>
                 "object_key ~ '^sponsors/applications/[0-9a-f-]{36}/evidence/[0-9a-f-]{36}$' AND " <>
                 "(status <> 'uploaded' OR uploaded_at IS NOT NULL) AND " <>
                 "((status = 'removed') = (removed_at IS NOT NULL)) AND " <>
                 "((status = 'removed') = (removed_reason IS NOT NULL)) AND " <>
                 "(removed_reason IS NULL OR removed_reason IN ('owner', 'abandoned')) AND " <>
                 "(submission_id IS NULL OR status = 'uploaded') AND " <>
                 "(object_deleted_at IS NULL OR (status = 'removed' AND submission_id IS NULL))"
           )

    create unique_index(:sponsor_application_evidence, [:object_key])
    create index(:sponsor_application_evidence, [:application_id, :status])
    create index(:sponsor_application_evidence, [:status, :upload_expires_at])

    execute("""
    CREATE FUNCTION sponsor_application_evidence_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'sponsor application evidence is never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_application_evidence_no_delete';
      END IF;
      IF NEW.application_id <> OLD.application_id OR NEW.object_key <> OLD.object_key
         OR NEW.kind <> OLD.kind OR NEW.content_type <> OLD.content_type
         OR NEW.byte_size <> OLD.byte_size OR NEW.file_name <> OLD.file_name
         OR NEW.created_by_user_id <> OLD.created_by_user_id THEN
        RAISE EXCEPTION 'evidence identity is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_application_evidence_immutable';
      END IF;
      IF OLD.submission_id IS NOT NULL AND (NEW.status <> OLD.status OR NEW.submission_id <> OLD.submission_id) THEN
        RAISE EXCEPTION 'submitted evidence is frozen'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_application_evidence_frozen';
      END IF;
      IF NEW.status <> OLD.status AND NOT (
           (OLD.status = 'pending_upload' AND NEW.status IN ('uploaded', 'removed')) OR
           (OLD.status = 'uploaded' AND NEW.status = 'removed')
         ) THEN
        RAISE EXCEPTION 'evidence status % cannot become %', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_application_evidence_transition';
      END IF;
      IF OLD.object_deleted_at IS NOT NULL AND NEW.object_deleted_at IS DISTINCT FROM OLD.object_deleted_at THEN
        RAISE EXCEPTION 'an object deletion is recorded once'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_application_evidence_deleted_once';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_application_evidence_guard
      BEFORE UPDATE OR DELETE ON sponsor_application_evidence
      FOR EACH ROW EXECUTE FUNCTION sponsor_application_evidence_guard();
    """)

    create table(:sponsor_application_change_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:sponsor_applications, type: :binary_id, on_delete: :restrict),
          null: false

      add :requested_by_operator_id,
          references(:platform_operators, type: :binary_id, on_delete: :restrict),
          null: false

      add :reason_code, :text, null: false
      add :fields, {:array, :text}, null: false
      add :message, :text, null: false
      add :application_revision, :bigint, null: false
      add :requested_at, :utc_datetime_usec, null: false

      add :resolved_by_submission_id,
          references(:sponsor_application_submissions, type: :binary_id, on_delete: :restrict)

      add :resolved_at, :utc_datetime_usec
    end

    create constraint(:sponsor_application_change_requests, :shape,
             check:
               "reason_code ~ '^[a-z][a-z0-9_]{1,59}$' AND cardinality(fields) BETWEEN 1 AND 14 AND " <>
                 "char_length(message) BETWEEN 1 AND 2000 AND " <>
                 "((resolved_at IS NULL) = (resolved_by_submission_id IS NULL))"
           )

    create unique_index(:sponsor_application_change_requests, [:application_id],
             where: "resolved_at IS NULL",
             name: :sponsor_application_change_requests_one_open_index
           )

    execute("""
    CREATE FUNCTION sponsor_application_change_requests_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' OR OLD.resolved_at IS NOT NULL
         OR NEW.application_id <> OLD.application_id OR NEW.requested_by_operator_id <> OLD.requested_by_operator_id
         OR NEW.reason_code <> OLD.reason_code OR NEW.fields <> OLD.fields OR NEW.message <> OLD.message
         OR NEW.application_revision <> OLD.application_revision OR NEW.requested_at <> OLD.requested_at THEN
        RAISE EXCEPTION 'a change request can only be resolved, once'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_application_change_requests_immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_application_change_requests_guard
      BEFORE UPDATE OR DELETE ON sponsor_application_change_requests
      FOR EACH ROW EXECUTE FUNCTION sponsor_application_change_requests_guard();
    """)

    create table(:sponsor_application_contact_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:sponsor_applications, type: :binary_id, on_delete: :restrict),
          null: false

      add :email_digest, :binary, null: false
      add :code_verifier, :binary, null: false
      add :attempts, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :superseded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:sponsor_application_contact_codes, :shape,
             check:
               "octet_length(email_digest) = 32 AND octet_length(code_verifier) = 32 AND " <>
                 "attempts BETWEEN 0 AND 5 AND expires_at > inserted_at"
           )

    create unique_index(:sponsor_application_contact_codes, [:application_id],
             where: "consumed_at IS NULL AND superseded_at IS NULL",
             name: :sponsor_application_contact_codes_one_live_index
           )

    create table(:sponsor_application_notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:sponsor_applications, type: :binary_id, on_delete: :restrict),
          null: false

      add :kind, :text, null: false
      add :recipient, :text, null: false
      add :status, :text, null: false
      add :suppressed_reason, :text
      add :dedupe_key, :text, null: false
      add :oban_job_id, :bigint

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:sponsor_application_notifications, :shape,
             check:
               "kind IN ('application_received', 'application_resubmitted', 'changes_requested', 'contact_verification_code') AND " <>
                 "recipient IN ('applicant', 'contact') AND status IN ('queued', 'suppressed') AND " <>
                 "((status = 'suppressed') = (suppressed_reason IS NOT NULL)) AND " <>
                 "(suppressed_reason IS NULL OR suppressed_reason ~ '^[a-z][a-z0-9_]{1,59}$') AND " <>
                 "char_length(dedupe_key) BETWEEN 1 AND 200"
           )

    create unique_index(:sponsor_application_notifications, [:dedupe_key])

    for table <- ~w(sponsor_application_notifications) do
      execute("""
      CREATE TRIGGER #{table}_append_only
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION sponsor_append_only();
      """)
    end
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM sponsor_application_evidence)
         OR EXISTS (SELECT 1 FROM sponsor_application_change_requests)
         OR EXISTS (SELECT 1 FROM sponsor_application_notifications)
         OR EXISTS (SELECT 1 FROM sponsor_applications WHERE contact_email_verified_at IS NOT NULL)
         OR EXISTS (SELECT 1 FROM operator_permission_grants WHERE permission LIKE 'sponsors.%') THEN
        RAISE EXCEPTION 'SF-114 rollback refused: evidence, change requests, notifications, contact verifications or sponsor grants exist';
      END IF;
    END;
    $$;
    """)

    drop table(:sponsor_application_notifications)
    drop table(:sponsor_application_contact_codes)
    drop table(:sponsor_application_change_requests)
    execute("DROP FUNCTION sponsor_application_change_requests_guard()")
    drop table(:sponsor_application_evidence)
    execute("DROP FUNCTION sponsor_application_evidence_guard()")
    drop constraint(:sponsor_applications, :contact_verification)

    alter table(:sponsor_applications) do
      remove :contact_email_verified_at
      remove :contact_email_verified_digest
    end

    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{list(@old_permissions)})"
           )
  end
end
