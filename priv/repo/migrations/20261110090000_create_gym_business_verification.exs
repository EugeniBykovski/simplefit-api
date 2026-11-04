defmodule SimpleFit.Repo.Migrations.CreateGymBusinessVerification do
  @moduledoc """
  SF-103: gym business verification (OG7; ADR 0026 amendment SF-103).

  * `gym_verification_applications` - a gym's application: the business
    details the owner declares, its status (`draft`, `submitted`,
    `changes_requested`, `approved`, `rejected`, `revoked`) and a revision
    that every owner change bumps. At most one current application per gym
    (`draft`, `submitted`, `changes_requested` or `approved`); a rejected or
    revoked one stays as history and a new application starts from nothing.
    A trigger allows only the reviewed transitions and freezes the content
    once submitted.
  * `gym_verification_evidence` - documents uploaded to private storage for
    one application (the composite key makes another gym's application
    impossible): a server-built object key, an allowlisted content type and
    an exact size, `pending_upload` until the server has seen the object,
    then `uploaded`; `removed` by the owner before submission. Evidence that
    was part of a submission is frozen.
  * `gym_verification_events` - the append-only history: submissions,
    operator decisions with their reason codes, and operator downloads of
    evidence. Each names the application revision and the evidence it
    covered, and either the owner (`actor_user_id`) or the operator.

  Nothing here is public, nothing is derived from Stripe, and no row is
  deleted (the SF-95 purge switch of test cleanup excepted).
  """

  use Ecto.Migration

  @gym_previous ~w(gym_created staff_membership_created ownership_transferred
                   staff_membership_ended primary_location_set setup_completed draft_discarded
                   first_run_completed first_run_dismissed staff_invited
                   staff_invitation_cancelled staff_invitation_accepted
                   staff_invitation_declined staff_role_changed
                   member_join_requested member_join_approved member_join_auto_approved
                   member_join_rejected member_join_cancelled member_ended
                   member_invited member_invitation_cancelled member_invitation_accepted
                   member_invitation_declined join_code_rotated join_code_disabled
                   member_auto_approval_changed
                   venue_created venue_updated venue_deactivated
                   class_template_created class_template_updated class_template_archived
                   class_series_created class_series_updated class_series_cancelled
                   class_occurrence_created class_occurrence_rescheduled class_occurrence_cancelled
                   class_instructor_changed class_capacity_changed class_instructor_released
                   class_booking_created class_booking_cancelled class_bookings_released
                   class_check_in_recorded
                   saas_subscription_requested saas_subscription_activated
                   saas_subscription_cancellation_scheduled saas_subscription_cancelled
                   saas_subscription_expired
                   member_product_created member_product_version_created
                   member_product_version_published member_product_price_created
                   member_product_retired
                   member_product_subscription_requested member_product_subscription_activated
                   member_product_subscription_cancellation_scheduled
                   member_product_subscription_cancelled member_product_subscription_expired
                   saas_checkout_started saas_subscription_renewed saas_subscription_reactivated
                   saas_payment_failed saas_refund_recorded saas_dispute_recorded)

  @gym_new ~w(business_verification_submitted business_verification_approved
              business_verification_rejected business_verification_changes_requested
              business_verification_revoked)

  @statuses ~w(draft submitted changes_requested approved rejected revoked)
  @current ~w(draft submitted changes_requested approved)
  @content_types ~w(application/pdf image/jpeg image/png)
  @kinds ~w(registration_extract proof_of_address other)
  @events ~w(submitted approved rejected changes_requested revoked evidence_downloaded)
  @max_bytes 10 * 1024 * 1024

  def up do
    create table(:gym_verification_applications) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :status, :text, null: false
      add :revision, :integer, null: false, default: 1
      # The requirement policy the application was created under.
      add :policy_version, :text, null: false
      add :legal_name, :text
      add :registration_country, :text
      add :registration_number, :text
      add :address_line, :text
      add :postal_code, :text
      add :city, :text
      add :website, :text
      add :created_by_user_id, :binary_id, null: false
      add :submitted_at, :utc_datetime_usec
      add :submitted_revision, :integer
      add :submitted_by_user_id, :binary_id
      add :decided_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_verification_applications, [:id, :gym_id])

    create unique_index(:gym_verification_applications, [:gym_id],
             where: "status IN (#{quoted(@current)})",
             name: :gym_verification_applications_one_current_index
           )

    create index(:gym_verification_applications, [:status, :submitted_at, :id])

    create constraint(:gym_verification_applications, :status_values,
             check: "status IN (#{quoted(@statuses)})"
           )

    create constraint(:gym_verification_applications, :revision_positive, check: "revision >= 1")

    create constraint(:gym_verification_applications, :country_format,
             check: "registration_country IS NULL OR registration_country ~ '^[A-Z]{2}$'"
           )

    # Anything past a draft was submitted once, with its required details.
    create constraint(:gym_verification_applications, :submission,
             check:
               "status = 'draft' OR (submitted_at IS NOT NULL AND submitted_revision IS NOT NULL " <>
                 "AND submitted_by_user_id IS NOT NULL AND legal_name IS NOT NULL " <>
                 "AND registration_country IS NOT NULL)"
           )

    # `decided_at` is the latest decision (kept through a resubmission).
    create constraint(:gym_verification_applications, :decision,
             check: "status IN ('draft', 'submitted') OR decided_at IS NOT NULL"
           )

    create table(:gym_verification_evidence) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :application_id,
          references(:gym_verification_applications,
            with: [gym_id: :gym_id],
            on_delete: :delete_all
          ),
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
      # The first submitted revision that included it; frozen from then on.
      add :submitted_revision, :integer
      # When the storage object of a removed or abandoned upload was deleted.
      add :object_deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_verification_evidence, [:object_key])
    create index(:gym_verification_evidence, [:application_id, :inserted_at, :id])

    create index(:gym_verification_evidence, [:status, :upload_expires_at],
             where: "object_deleted_at IS NULL AND status <> 'uploaded'",
             name: :gym_verification_evidence_cleanup_index
           )

    create constraint(:gym_verification_evidence, :kind_values,
             check: "kind IN (#{quoted(@kinds)})"
           )

    create constraint(:gym_verification_evidence, :status_values,
             check: "status IN ('pending_upload', 'uploaded', 'removed')"
           )

    create constraint(:gym_verification_evidence, :content_type_values,
             check: "content_type IN (#{quoted(@content_types)})"
           )

    create constraint(:gym_verification_evidence, :byte_size_range,
             check: "byte_size BETWEEN 1 AND #{@max_bytes}"
           )

    create constraint(:gym_verification_evidence, :file_name_length,
             check: "char_length(file_name) BETWEEN 1 AND 120"
           )

    create constraint(:gym_verification_evidence, :lifecycle,
             check:
               "(status <> 'uploaded' OR uploaded_at IS NOT NULL) AND " <>
                 "(status <> 'removed' OR removed_at IS NOT NULL) AND " <>
                 "(submitted_revision IS NULL OR (uploaded_at IS NOT NULL AND status = 'uploaded')) AND " <>
                 "(object_deleted_at IS NULL OR status = 'removed')"
           )

    create table(:gym_verification_events) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :application_id,
          references(:gym_verification_applications,
            with: [gym_id: :gym_id],
            on_delete: :delete_all
          ),
          null: false

      add :event, :text, null: false
      add :reason_code, :text
      add :application_revision, :integer, null: false
      add :evidence_ids, {:array, :binary_id}, null: false, default: []
      add :actor_user_id, :binary_id
      add :operator, :text
      add :occurred_at, :utc_datetime_usec, null: false
      # The history's total order (two events can share a timestamp).
      add :seq, :bigserial, null: false
    end

    create index(:gym_verification_events, [:application_id, :seq])

    create constraint(:gym_verification_events, :event_values,
             check: "event IN (#{quoted(@events)})"
           )

    # The owner submits; an operator decides and downloads. Never both, never neither.
    create constraint(:gym_verification_events, :actor,
             check:
               "(event = 'submitted' AND actor_user_id IS NOT NULL AND operator IS NULL) OR " <>
                 "(event <> 'submitted' AND actor_user_id IS NULL AND operator IS NOT NULL " <>
                 "AND char_length(operator) BETWEEN 3 AND 254)"
           )

    create constraint(:gym_verification_events, :reason,
             check:
               "(event IN ('rejected', 'changes_requested', 'revoked')) = (reason_code IS NOT NULL)"
           )

    application_guard()
    evidence_guard()

    execute("""
    CREATE FUNCTION gym_verification_events_append_only() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'gym verification events are append-only'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_events_append_only';
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_verification_events_append_only BEFORE UPDATE ON gym_verification_events
    FOR EACH ROW EXECUTE FUNCTION gym_verification_events_append_only()
    """)

    for table <-
          ~w(gym_verification_applications gym_verification_evidence gym_verification_events) do
      execute("""
      CREATE TRIGGER #{table}_guard_delete BEFORE DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION gym_schedule_guard_delete()
      """)
    end

    # -- Audit ------------------------------------------------------------------------------

    alter table(:gym_audit_events) do
      add :verification_application_id, :binary_id
    end

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@gym_previous ++ @gym_new)})"
           )
  end

  def down do
    execute("DELETE FROM gym_audit_events WHERE event_type IN (#{quoted(@gym_new)})")
    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@gym_previous)})"
           )

    alter table(:gym_audit_events) do
      remove :verification_application_id
    end

    drop table(:gym_verification_events)
    drop table(:gym_verification_evidence)
    drop table(:gym_verification_applications)

    for function <- ~w(gym_verification_events_append_only gym_verification_evidence_guard
                       gym_verification_applications_guard) do
      execute("DROP FUNCTION IF EXISTS #{function}()")
    end
  end

  # Allowed status changes, an immutable identity, a revision that never goes
  # back, and content frozen from submission on (only a draft or an
  # application with changes requested is edited, and only by the owner).
  defp application_guard do
    execute("""
    CREATE FUNCTION gym_verification_applications_guard() RETURNS trigger AS $$
    BEGIN
      IF NEW.id <> OLD.id OR NEW.gym_id <> OLD.gym_id
         OR NEW.created_by_user_id <> OLD.created_by_user_id
         OR NEW.policy_version <> OLD.policy_version OR NEW.inserted_at <> OLD.inserted_at THEN
        RAISE EXCEPTION 'a verification application keeps its identity'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_applications_identity';
      END IF;

      IF NEW.revision < OLD.revision THEN
        RAISE EXCEPTION 'a verification application revision never goes back'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_applications_revision';
      END IF;

      IF NEW.status = OLD.status THEN
        IF OLD.status NOT IN ('draft', 'changes_requested') THEN
          RAISE EXCEPTION 'a % verification application is frozen', OLD.status
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_applications_frozen';
        END IF;
      ELSIF NOT ((OLD.status, NEW.status) IN (
          ('draft', 'submitted'), ('changes_requested', 'submitted'),
          ('submitted', 'approved'), ('submitted', 'rejected'),
          ('submitted', 'changes_requested'), ('approved', 'revoked'))) THEN
        RAISE EXCEPTION 'verification transition % -> % is not allowed', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_applications_transition';
      END IF;

      -- A decision (or a revocation) never changes what was submitted.
      IF OLD.status IN ('submitted', 'approved') AND (
           NEW.revision <> OLD.revision
           OR NEW.legal_name IS DISTINCT FROM OLD.legal_name
           OR NEW.registration_country IS DISTINCT FROM OLD.registration_country
           OR NEW.registration_number IS DISTINCT FROM OLD.registration_number
           OR NEW.address_line IS DISTINCT FROM OLD.address_line
           OR NEW.postal_code IS DISTINCT FROM OLD.postal_code
           OR NEW.city IS DISTINCT FROM OLD.city
           OR NEW.website IS DISTINCT FROM OLD.website
           OR NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
           OR NEW.submitted_revision IS DISTINCT FROM OLD.submitted_revision
           OR NEW.submitted_by_user_id IS DISTINCT FROM OLD.submitted_by_user_id) THEN
        RAISE EXCEPTION 'a decision never changes the submitted application'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_applications_frozen';
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_verification_applications_guard BEFORE UPDATE ON gym_verification_applications
    FOR EACH ROW EXECUTE FUNCTION gym_verification_applications_guard()
    """)
  end

  # Evidence keeps what was uploaded (object, type, size, name, owner);
  # `pending_upload -> uploaded | removed`, `uploaded -> removed` only while it
  # was never submitted; the submitted revision is set once; the object
  # deletion is recorded once, on removed evidence only.
  defp evidence_guard do
    execute("""
    CREATE FUNCTION gym_verification_evidence_guard() RETURNS trigger AS $$
    BEGIN
      IF NEW.id <> OLD.id OR NEW.gym_id <> OLD.gym_id OR NEW.application_id <> OLD.application_id
         OR NEW.kind <> OLD.kind OR NEW.object_key <> OLD.object_key
         OR NEW.content_type <> OLD.content_type OR NEW.byte_size <> OLD.byte_size
         OR NEW.file_name <> OLD.file_name OR NEW.created_by_user_id <> OLD.created_by_user_id
         OR NEW.upload_expires_at <> OLD.upload_expires_at OR NEW.inserted_at <> OLD.inserted_at
         OR (OLD.uploaded_at IS NOT NULL AND NEW.uploaded_at IS DISTINCT FROM OLD.uploaded_at)
         OR (OLD.removed_at IS NOT NULL AND NEW.removed_at IS DISTINCT FROM OLD.removed_at)
         OR (OLD.submitted_revision IS NOT NULL
             AND NEW.submitted_revision IS DISTINCT FROM OLD.submitted_revision)
         OR (OLD.object_deleted_at IS NOT NULL
             AND NEW.object_deleted_at IS DISTINCT FROM OLD.object_deleted_at) THEN
        RAISE EXCEPTION 'verification evidence keeps what was uploaded'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_evidence_identity';
      END IF;

      IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (
          ('pending_upload', 'uploaded'), ('pending_upload', 'removed'), ('uploaded', 'removed'))) THEN
        RAISE EXCEPTION 'evidence transition % -> % is not allowed', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_evidence_transition';
      END IF;

      IF OLD.submitted_revision IS NOT NULL AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'submitted evidence is frozen'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_verification_evidence_frozen';
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_verification_evidence_guard BEFORE UPDATE ON gym_verification_evidence
    FOR EACH ROW EXECUTE FUNCTION gym_verification_evidence_guard()
    """)
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
