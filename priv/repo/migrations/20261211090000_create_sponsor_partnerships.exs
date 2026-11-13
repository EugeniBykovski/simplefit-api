defmodule SimpleFit.Repo.Migrations.CreateSponsorPartnerships do
  @moduledoc """
  SF-130: sponsor partnership preferences and nonbinding partnership proposals
  (ADR 0034; D-SA21, D-SA37-D-SA39).

  * Operator permissions `sponsors.proposals.read`, `.claim`, `.request_changes`,
    `.accept` and `.decline`. Nothing is granted.
  * `sponsor_partnership_preferences` - one row per organization: interests, markets
    and goals, editable by its owner or managers. A trigger raises `revision` on every
    update and forbids deletes and moving the row. The application's own submitted
    answers are never touched: they stay in `sponsor_application_submissions`.
  * `sponsor_partnership_proposals` - an organization's general partnership inquiry
    (`kind` `general_inquiry` only: no opportunity inventory exists, D-SA21). Typed
    answer columns, no amount, budget, athlete, gym or person reference. Status
    `draft`, `submitted`, `under_review`, `changes_requested`, `accepted`,
    `declined`, `withdrawn`; the trigger allows only the lifecycle's transitions,
    locks answers outside `draft` and `changes_requested`, keeps the organization,
    creator and creating request immutable, raises `revision` and forbids deletes.
  * `sponsor_partnership_proposal_submissions` - one append-only row per submission:
    a schema-tagged JSONB snapshot (`sponsor-partnership-proposal-snapshot.v1`) and
    its SHA-256, the policy version and the idempotency key with its request digest.
  * `sponsor_partnership_change_requests` - an operator's request for changes: reason
    code, the answers to revisit and a message. At most one open; resolved once by the
    next submission, never edited.
  * `sponsor_partnership_events` - append-only history, ids and codes only.

  Rolling back refuses while any preference or proposal exists or a new permission is
  granted.
  """

  use Ecto.Migration

  @statuses ~w(draft submitted under_review changes_requested accepted declined withdrawn)
  @interests ~w(sponsored_challenges sponsored_events equipment_partnerships gym_partnerships
                coach_partnerships marketplace community_campaigns content other)

  @sf128_permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                        sponsors.applications.claim sponsors.applications.request_changes
                        sponsors.applications.approve sponsors.applications.reject
                        sponsors.applications.read_files sponsors.restrict
                        platform.dashboard.read system.health.read
                        users.read users.reveal_email users.restrict users.sessions.revoke
                        gyms.read coaches.read fighters.read system.jobs.read
                        billing.read billing.reconciliation.read config.read config.flags.write)

  @new_permissions ~w(sponsors.proposals.read sponsors.proposals.claim
                      sponsors.proposals.request_changes sponsors.proposals.accept
                      sponsors.proposals.decline)

  defp list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  # The shared answer checks of preferences and proposals (SF-113's vocabularies).
  defp markets_check do
    "interests <@ ARRAY[#{list(@interests)}]::text[] AND cardinality(interests) <= 9 AND " <>
      "(market_scope IS NULL OR market_scope IN ('global', 'countries', 'cities')) AND " <>
      "cardinality(market_countries) <= 50 AND cardinality(market_cities) <= 20 AND " <>
      "(market_scope IS DISTINCT FROM 'global' OR " <>
      "(cardinality(market_countries) = 0 AND cardinality(market_cities) = 0))"
  end

  def up do
    permissions(@sf128_permissions ++ @new_permissions)

    ## Preferences

    create table(:sponsor_partnership_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:sponsor_organizations, type: :binary_id, on_delete: :restrict),
          null: false

      add :revision, :bigint, null: false, default: 1
      add :interests, {:array, :text}, null: false, default: []
      add :market_scope, :text
      add :market_countries, {:array, :text}, null: false, default: []
      add :market_cities, {:array, :text}, null: false, default: []
      add :goals, :text
      add :updated_by_user_id, :binary_id, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sponsor_partnership_preferences, [:organization_id])

    create constraint(:sponsor_partnership_preferences, :answers,
             check:
               markets_check() <>
                 " AND (goals IS NULL OR char_length(goals) BETWEEN 1 AND 2000) AND revision >= 1"
           )

    execute("""
    CREATE FUNCTION sponsor_partnership_preferences_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'partnership preferences are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_partnership_preferences_no_delete';
      END IF;
      IF NEW.organization_id <> OLD.organization_id THEN
        RAISE EXCEPTION 'partnership preferences belong to one organization'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_partnership_preferences_immutable_organization';
      END IF;
      NEW.revision := OLD.revision + 1;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_partnership_preferences_guard
      BEFORE UPDATE OR DELETE ON sponsor_partnership_preferences
      FOR EACH ROW EXECUTE FUNCTION sponsor_partnership_preferences_guard();
    """)

    ## Proposals

    create table(:sponsor_partnership_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:sponsor_organizations, type: :binary_id, on_delete: :restrict),
          null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false

      add :kind, :text, null: false
      add :status, :text, null: false
      add :revision, :bigint, null: false, default: 1
      add :client_request_id, :binary_id, null: false
      add :request_sha256, :binary, null: false
      add :withdrawal_request_id, :binary_id

      add :title, :text
      add :interests, {:array, :text}, null: false, default: []
      add :market_scope, :text
      add :market_countries, {:array, :text}, null: false, default: []
      add :market_cities, {:array, :text}, null: false, default: []
      add :summary, :text

      add :submitted_at, :utc_datetime_usec
      add :decided_at, :utc_datetime_usec
      add :withdrawn_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:sponsor_partnership_proposals, :status_values,
             check: "status IN (#{list(@statuses)}) AND kind = 'general_inquiry'"
           )

    create constraint(:sponsor_partnership_proposals, :answers,
             check:
               markets_check() <>
                 " AND (title IS NULL OR (char_length(title) BETWEEN 1 AND 120 AND title = btrim(title)))" <>
                 " AND (summary IS NULL OR char_length(summary) BETWEEN 1 AND 4000)"
           )

    create constraint(:sponsor_partnership_proposals, :lifecycle,
             check:
               "(status IN ('accepted', 'declined')) = (decided_at IS NOT NULL) AND " <>
                 "(status = 'withdrawn') = (withdrawn_at IS NOT NULL) AND " <>
                 "(status = 'withdrawn') = (withdrawal_request_id IS NOT NULL) AND " <>
                 "(status = 'draft' OR status = 'withdrawn' OR submitted_at IS NOT NULL) AND " <>
                 "octet_length(request_sha256) = 32 AND revision >= 1"
           )

    create unique_index(:sponsor_partnership_proposals, [:organization_id, :client_request_id])
    create index(:sponsor_partnership_proposals, [:organization_id, :inserted_at, :id])
    create index(:sponsor_partnership_proposals, [:status, :submitted_at, :id])

    execute("""
    CREATE FUNCTION sponsor_partnership_proposals_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'partnership proposals are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_partnership_proposals_no_delete';
      END IF;
      IF NEW.organization_id <> OLD.organization_id OR NEW.created_by_user_id <> OLD.created_by_user_id
         OR NEW.kind <> OLD.kind OR NEW.client_request_id <> OLD.client_request_id
         OR NEW.request_sha256 <> OLD.request_sha256 THEN
        RAISE EXCEPTION 'a proposal''s organization, creator and kind are immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_partnership_proposals_immutable';
      END IF;
      IF OLD.status NOT IN ('draft', 'changes_requested') AND (
           NEW.title IS DISTINCT FROM OLD.title OR NEW.interests IS DISTINCT FROM OLD.interests OR
           NEW.market_scope IS DISTINCT FROM OLD.market_scope OR
           NEW.market_countries IS DISTINCT FROM OLD.market_countries OR
           NEW.market_cities IS DISTINCT FROM OLD.market_cities OR NEW.summary IS DISTINCT FROM OLD.summary) THEN
        RAISE EXCEPTION 'answers of a % proposal are immutable', OLD.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_partnership_proposals_answers_locked';
      END IF;
      IF NEW.status <> OLD.status AND NOT (
           (OLD.status = 'draft' AND NEW.status IN ('submitted', 'withdrawn')) OR
           (OLD.status = 'submitted' AND NEW.status IN ('under_review', 'withdrawn')) OR
           (OLD.status = 'under_review' AND NEW.status IN ('changes_requested', 'accepted', 'declined', 'withdrawn')) OR
           (OLD.status = 'changes_requested' AND NEW.status IN ('submitted', 'withdrawn'))
         ) THEN
        RAISE EXCEPTION 'proposal status % cannot become %', OLD.status, NEW.status
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_partnership_proposals_transition';
      END IF;
      NEW.revision := OLD.revision + 1;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_partnership_proposals_guard
      BEFORE UPDATE OR DELETE ON sponsor_partnership_proposals
      FOR EACH ROW EXECUTE FUNCTION sponsor_partnership_proposals_guard();
    """)

    ## Submissions

    create table(:sponsor_partnership_proposal_submissions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :proposal_id,
          references(:sponsor_partnership_proposals, type: :binary_id, on_delete: :restrict),
          null: false

      add :sequence, :integer, null: false
      add :proposal_revision, :bigint, null: false
      add :policy_version, :text, null: false
      add :snapshot, :map, null: false
      add :snapshot_sha256, :binary, null: false
      add :client_request_id, :binary_id, null: false
      add :request_sha256, :binary, null: false
      add :submitted_by_user_id, :binary_id, null: false
      add :submitted_at, :utc_datetime_usec, null: false
    end

    create constraint(:sponsor_partnership_proposal_submissions, :shape,
             check:
               "sequence >= 1 AND proposal_revision >= 1 AND jsonb_typeof(snapshot) = 'object' AND " <>
                 "snapshot->>'schema' = 'sponsor-partnership-proposal-snapshot.v1' AND " <>
                 "octet_length(snapshot_sha256) = 32 AND octet_length(request_sha256) = 32"
           )

    create unique_index(:sponsor_partnership_proposal_submissions, [:proposal_id, :sequence])

    create unique_index(:sponsor_partnership_proposal_submissions, [
             :proposal_id,
             :client_request_id
           ])

    ## Change requests

    create table(:sponsor_partnership_change_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :proposal_id,
          references(:sponsor_partnership_proposals, type: :binary_id, on_delete: :restrict),
          null: false

      add :requested_by_operator_id,
          references(:platform_operators, type: :binary_id, on_delete: :restrict),
          null: false

      add :reason_code, :text, null: false
      add :fields, {:array, :text}, null: false
      add :message, :text, null: false
      add :proposal_revision, :bigint, null: false
      add :requested_at, :utc_datetime_usec, null: false

      add :resolved_by_submission_id,
          references(:sponsor_partnership_proposal_submissions,
            type: :binary_id,
            on_delete: :restrict
          )

      add :resolved_at, :utc_datetime_usec
    end

    create constraint(:sponsor_partnership_change_requests, :shape,
             check:
               "reason_code ~ '^[a-z][a-z0-9_]{1,59}$' AND cardinality(fields) BETWEEN 1 AND 6 AND " <>
                 "fields <@ ARRAY['title', 'interests', 'market_scope', 'market_countries', 'market_cities', 'summary']::text[] AND " <>
                 "char_length(message) BETWEEN 1 AND 2000 AND " <>
                 "((resolved_at IS NULL) = (resolved_by_submission_id IS NULL))"
           )

    create unique_index(:sponsor_partnership_change_requests, [:proposal_id],
             where: "resolved_at IS NULL",
             name: :sponsor_partnership_change_requests_one_open_index
           )

    execute("""
    CREATE FUNCTION sponsor_partnership_change_requests_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' OR OLD.resolved_at IS NOT NULL
         OR NEW.proposal_id <> OLD.proposal_id OR NEW.requested_by_operator_id <> OLD.requested_by_operator_id
         OR NEW.reason_code <> OLD.reason_code OR NEW.fields <> OLD.fields OR NEW.message <> OLD.message
         OR NEW.proposal_revision <> OLD.proposal_revision OR NEW.requested_at <> OLD.requested_at THEN
        RAISE EXCEPTION 'a change request can only be resolved, once'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'sponsor_partnership_change_requests_immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sponsor_partnership_change_requests_guard
      BEFORE UPDATE OR DELETE ON sponsor_partnership_change_requests
      FOR EACH ROW EXECUTE FUNCTION sponsor_partnership_change_requests_guard();
    """)

    ## History

    create table(:sponsor_partnership_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:sponsor_organizations, type: :binary_id, on_delete: :restrict),
          null: false

      add :proposal_id,
          references(:sponsor_partnership_proposals, type: :binary_id, on_delete: :restrict)

      add :occurred_at, :utc_datetime_usec, null: false
      add :event, :text, null: false
      add :outcome, :text, null: false
      add :actor_user_id, :binary_id
      add :actor_kind, :text, null: false
      add :from_status, :text
      add :to_status, :text
      add :revision, :bigint
      add :submission_id, :binary_id
      add :reason_code, :text
      add :request_id, :text
    end

    create constraint(:sponsor_partnership_events, :codes,
             check:
               "event ~ '^[a-z][a-z0-9_.]{1,79}$' AND outcome IN ('allowed', 'refused') AND " <>
                 "actor_kind IN ('sponsor_member', 'operator') AND " <>
                 "(from_status IS NULL OR from_status IN (#{list(@statuses)})) AND " <>
                 "(to_status IS NULL OR to_status IN (#{list(@statuses)})) AND " <>
                 "(reason_code IS NULL OR reason_code ~ '^[a-z][a-z0-9_]{1,59}$') AND " <>
                 "(request_id IS NULL OR char_length(request_id) <= 200)"
           )

    create index(:sponsor_partnership_events, [:proposal_id, :occurred_at])
    create index(:sponsor_partnership_events, [:organization_id, :occurred_at])

    for table <- ~w(sponsor_partnership_proposal_submissions sponsor_partnership_events) do
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
      IF EXISTS (SELECT 1 FROM sponsor_partnership_proposals)
         OR EXISTS (SELECT 1 FROM sponsor_partnership_preferences) THEN
        RAISE EXCEPTION 'SF-130 rollback refused: partnership data exists';
      END IF;
    END;
    $$;
    """)

    drop table(:sponsor_partnership_events)
    drop table(:sponsor_partnership_change_requests)
    execute("DROP FUNCTION sponsor_partnership_change_requests_guard()")
    drop table(:sponsor_partnership_proposal_submissions)
    drop table(:sponsor_partnership_proposals)
    execute("DROP FUNCTION sponsor_partnership_proposals_guard()")
    drop table(:sponsor_partnership_preferences)
    execute("DROP FUNCTION sponsor_partnership_preferences_guard()")
    permissions(@sf128_permissions)
  end

  defp permissions(values) do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{list(values)})"
           )
  end
end
