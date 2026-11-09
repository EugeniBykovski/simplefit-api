defmodule SimpleFit.Repo.Migrations.CreateSponsorApplications do
  @moduledoc """
  SF-113: sponsor applications (ADR 0031; lifecycle from SF-107, proposed).

  * `sponsor_applications` - one applicant's application: typed answer columns
    (SP1-SP6), status, a trigger-raised `revision`, and the creating request's
    `client_request_id`. At most one current (non-terminal) application per
    applicant. Answers change only while `draft` or `changes_requested`; legal
    status transitions only; never deleted. Separate from organizations: an
    organization names its application (`sponsor_organizations.source_application_id`,
    foreign key added here), never the other way round.
  * `sponsor_application_submissions` - one immutable row per submission: a
    versioned, schema-tagged JSONB snapshot of the answers (with its SHA-256), the
    validation policy version, the declaration accepted, and the idempotency key.
    Append-only.
  * `sponsor_application_events` - append-only history (created, updated,
    submitted, resubmitted, refused submissions and conflicts). Ids and codes only.

  Triggers bind the application's database role, not a superuser (D-SA28).
  """

  use Ecto.Migration

  @statuses ~w(draft submitted under_review changes_requested approved rejected withdrawn)
  @current ~w(draft submitted under_review changes_requested)
  @industries ~w(boxing_equipment sports_apparel nutrition recovery fitness_technology events other)
  @interests ~w(sponsored_challenges sponsored_events equipment_partnerships gym_partnerships
                coach_partnerships marketplace community_campaigns content other)
  @budget_bands ~w(eur_under_5000 eur_5000_20000 eur_20000_50000 eur_50000_100000 eur_100000_plus
                   to_be_discussed)

  defp list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  def up do
    create table(:sponsor_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :applicant_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false

      add :status, :text, null: false
      add :revision, :bigint, null: false, default: 1
      add :client_request_id, :binary_id, null: false

      add :company_name, :text
      add :website, :text
      add :country_code, :text
      add :industry, :text
      add :contact_full_name, :text
      add :contact_position, :text
      add :contact_email, :text
      add :contact_phone, :text
      add :interests, {:array, :text}, null: false, default: []
      add :market_scope, :text
      add :market_countries, {:array, :text}, null: false, default: []
      add :market_cities, {:array, :text}, null: false, default: []
      add :budget_band, :text
      add :goals, :text

      add :submitted_at, :utc_datetime_usec
      add :decided_at, :utc_datetime_usec
      add :withdrawn_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:sponsor_applications, :status_values,
             check: "status IN (#{list(@statuses)})"
           )

    create constraint(:sponsor_applications, :answers,
             check:
               "(company_name IS NULL OR (char_length(company_name) BETWEEN 1 AND 200 AND company_name = btrim(company_name))) AND " <>
                 "(website IS NULL OR (char_length(website) <= 200 AND website ~ '^https://[^[:space:]]+$')) AND " <>
                 "(country_code IS NULL OR country_code ~ '^[A-Z]{2}$') AND " <>
                 "(industry IS NULL OR industry IN (#{list(@industries)})) AND " <>
                 "(contact_full_name IS NULL OR char_length(contact_full_name) BETWEEN 1 AND 120) AND " <>
                 "(contact_position IS NULL OR char_length(contact_position) BETWEEN 1 AND 120) AND " <>
                 "(contact_email IS NULL OR (char_length(contact_email) <= 254 AND contact_email = lower(btrim(contact_email)) AND position('@' IN contact_email) > 1)) AND " <>
                 "(contact_phone IS NULL OR contact_phone ~ '^\\+[1-9][0-9]{6,14}$') AND " <>
                 "interests <@ ARRAY[#{list(@interests)}]::text[] AND " <>
                 "(market_scope IS NULL OR market_scope IN ('global', 'countries', 'cities')) AND " <>
                 "cardinality(market_countries) <= 50 AND cardinality(market_cities) <= 20 AND " <>
                 "(budget_band IS NULL OR budget_band IN (#{list(@budget_bands)})) AND " <>
                 "(goals IS NULL OR char_length(goals) BETWEEN 1 AND 2000)"
           )

    create constraint(:sponsor_applications, :lifecycle,
             check:
               "(status = 'draft') = (submitted_at IS NULL) AND " <>
                 "(status IN ('approved', 'rejected')) = (decided_at IS NOT NULL) AND " <>
                 "(status = 'withdrawn') = (withdrawn_at IS NOT NULL) AND revision >= 1"
           )

    create unique_index(:sponsor_applications, [:applicant_user_id],
             where: "status IN (#{list(@current)})",
             name: :sponsor_applications_one_current_index
           )

    create unique_index(:sponsor_applications, [:applicant_user_id, :client_request_id])
    create index(:sponsor_applications, [:status, :submitted_at, :id])

    execute("""
    CREATE FUNCTION sponsor_applications_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'sponsor applications are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_applications_no_delete';
      END IF;
      IF NEW.applicant_user_id <> OLD.applicant_user_id OR NEW.client_request_id <> OLD.client_request_id THEN
        RAISE EXCEPTION 'an application''s applicant is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_applications_immutable_applicant';
      END IF;
      IF OLD.status NOT IN ('draft', 'changes_requested') AND (
           NEW.company_name IS DISTINCT FROM OLD.company_name OR NEW.website IS DISTINCT FROM OLD.website OR
           NEW.country_code IS DISTINCT FROM OLD.country_code OR NEW.industry IS DISTINCT FROM OLD.industry OR
           NEW.contact_full_name IS DISTINCT FROM OLD.contact_full_name OR
           NEW.contact_position IS DISTINCT FROM OLD.contact_position OR
           NEW.contact_email IS DISTINCT FROM OLD.contact_email OR NEW.contact_phone IS DISTINCT FROM OLD.contact_phone OR
           NEW.interests IS DISTINCT FROM OLD.interests OR NEW.market_scope IS DISTINCT FROM OLD.market_scope OR
           NEW.market_countries IS DISTINCT FROM OLD.market_countries OR
           NEW.market_cities IS DISTINCT FROM OLD.market_cities OR
           NEW.budget_band IS DISTINCT FROM OLD.budget_band OR NEW.goals IS DISTINCT FROM OLD.goals) THEN
        RAISE EXCEPTION 'answers of a % application are immutable', OLD.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_applications_answers_locked';
      END IF;
      IF NEW.status <> OLD.status AND NOT (
           (OLD.status = 'draft' AND NEW.status = 'submitted') OR
           (OLD.status = 'submitted' AND NEW.status IN ('under_review', 'withdrawn')) OR
           (OLD.status = 'under_review' AND NEW.status IN ('submitted', 'changes_requested', 'approved', 'rejected', 'withdrawn')) OR
           (OLD.status = 'changes_requested' AND NEW.status IN ('submitted', 'withdrawn'))
         ) THEN
        RAISE EXCEPTION 'application status % cannot become %', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_applications_transition';
      END IF;
      NEW.revision := OLD.revision + 1;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_applications_guard
      BEFORE UPDATE OR DELETE ON sponsor_applications
      FOR EACH ROW EXECUTE FUNCTION sponsor_applications_guard();
    """)

    create table(:sponsor_application_submissions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:sponsor_applications, type: :binary_id, on_delete: :restrict),
          null: false

      add :sequence, :integer, null: false
      add :application_revision, :bigint, null: false
      add :policy_version, :text, null: false
      add :declaration_document_id, :text, null: false
      add :declaration_version, :text, null: false
      add :declaration_language, :text, null: false
      add :declaration_content_sha256, :text, null: false
      add :snapshot, :map, null: false
      add :snapshot_sha256, :binary, null: false
      add :client_request_id, :binary_id, null: false
      add :request_sha256, :binary, null: false
      add :submitted_by_user_id, :binary_id, null: false
      add :submitted_at, :utc_datetime_usec, null: false
    end

    create constraint(:sponsor_application_submissions, :shape,
             check:
               "sequence >= 1 AND application_revision >= 1 AND " <>
                 "jsonb_typeof(snapshot) = 'object' AND snapshot->>'schema' = 'sponsor-application-snapshot.v1' AND " <>
                 "octet_length(snapshot_sha256) = 32 AND octet_length(request_sha256) = 32 AND " <>
                 "declaration_content_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create unique_index(:sponsor_application_submissions, [:application_id, :sequence])
    create unique_index(:sponsor_application_submissions, [:application_id, :client_request_id])

    create table(:sponsor_application_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:sponsor_applications, type: :binary_id, on_delete: :restrict),
          null: false

      add :occurred_at, :utc_datetime_usec, null: false
      add :event, :text, null: false
      add :outcome, :text, null: false
      add :actor_user_id, :binary_id
      add :from_status, :text
      add :to_status, :text
      add :revision, :bigint
      add :submission_id, :binary_id
      add :reason_code, :text
      add :request_id, :text
    end

    create constraint(:sponsor_application_events, :codes,
             check:
               "event ~ '^[a-z][a-z0-9_.]{1,79}$' AND outcome IN ('allowed', 'refused') AND " <>
                 "(from_status IS NULL OR from_status IN (#{list(@statuses)})) AND " <>
                 "(to_status IS NULL OR to_status IN (#{list(@statuses)})) AND " <>
                 "(reason_code IS NULL OR reason_code ~ '^[a-z][a-z0-9_]{1,59}$') AND " <>
                 "(request_id IS NULL OR char_length(request_id) <= 200)"
           )

    create index(:sponsor_application_events, [:application_id, :occurred_at])

    for table <- ~w(sponsor_application_submissions sponsor_application_events) do
      execute("""
      CREATE TRIGGER #{table}_append_only
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION sponsor_append_only();
      """)
    end

    # SF-112 left this column without its foreign key until the table existed.
    alter table(:sponsor_organizations) do
      modify :source_application_id,
             references(:sponsor_applications, type: :binary_id, on_delete: :restrict),
             from: :binary_id
    end
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM sponsor_applications) THEN
        RAISE EXCEPTION 'SF-113 rollback refused: sponsor applications exist';
      END IF;
    END;
    $$;
    """)

    alter table(:sponsor_organizations) do
      modify :source_application_id, :binary_id,
        from: references(:sponsor_applications, type: :binary_id, on_delete: :restrict)
    end

    drop table(:sponsor_application_events)
    drop table(:sponsor_application_submissions)
    drop table(:sponsor_applications)
    execute("DROP FUNCTION sponsor_applications_guard()")
  end
end
