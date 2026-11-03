defmodule SimpleFit.Repo.Migrations.CreateBillingAndGymCommerce do
  @moduledoc """
  SF-101: two independent commercial domains and their entitlement source
  (ADR 0026 amendment SF-101; SF-82 05 §2 concepts B and C; D-G09, D-G10).

  Platform SaaS (SimpleFit sells software to a gym; the gym is the
  subscriber, never its owner as a person):

  * `saas_plans` - a stable plan identity (`starter`, `growth`, ...).
  * `saas_plan_versions` - the contractual content of a plan: `draft`
    (editable, may be `archived` and restored), `published` (offered,
    immutable), `superseded` (a newer version was published; still
    referenced by its subscriptions) or `retired` (withdrawn). Every
    version records where its prices come from (`price_source`) and, once
    published, the approval it was published under.
  * `saas_price_versions` - one price per plan version, interval and
    currency, in integer minor units, or `quote_required` (Enterprise) with
    no amount: a missing price is never free. Rows are written only while
    their plan version is a draft and never updated.
  * `saas_plan_entitlements` - the features a plan version includes (keys
    from the application's registry), frozen with the version.
  * `gym_saas_subscriptions` - a gym's subscription to one price version:
    `pending_activation` (an intent: no access), `active`,
    `cancellation_scheduled`, `cancelled` or `expired`. At most one current
    (non-final) subscription per gym.
  * `gym_saas_subscription_periods` - the billing periods a subscription
    was activated or renewed for, from verified evidence only; never
    changed.

  Gym commerce (a gym sells its own products to its members; no relation to
  the SaaS tables):

  * `gym_member_products`, `gym_member_product_versions` (the same version
    lifecycle) and `gym_member_price_versions` (append-only prices of a
    product version, per currency).
  * `gym_member_product_subscriptions` - a member's pass or membership
    product: the same lifecycle, scoped to the member's gym.

  Activation:

  * `billing_activation_evidence` - verified evidence from a trusted
    payment provider (or a separately approved non-payment grant). The only
    way a subscription becomes `active`; unique per provider reference, so
    a replayed provider event activates nothing twice. No provider exists
    yet (D-G10), so in every deployed environment nothing writes here.

  Money is never a float: integer minor units in an ISO 4217 currency the
  application supports (its precision decides how a decimal amount maps to
  minor units, refusing anything finer). No VAT, discount, invoice, payment,
  refund or credit ledger exists.
  """

  use Ecto.Migration

  @previous ~w(gym_created staff_membership_created ownership_transferred
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
               class_check_in_recorded)

  @new ~w(saas_subscription_requested saas_subscription_activated
          saas_subscription_cancellation_scheduled saas_subscription_cancelled
          saas_subscription_expired
          member_product_created member_product_version_created
          member_product_version_published member_product_price_created
          member_product_retired
          member_product_subscription_requested member_product_subscription_activated
          member_product_subscription_cancellation_scheduled
          member_product_subscription_cancelled member_product_subscription_expired)

  @currencies ~w(PLN EUR USD GBP CHF CZK SEK NOK DKK HUF UAH JPY)

  @version_statuses "('draft', 'archived', 'published', 'superseded', 'retired')"
  @subscription_statuses "('pending_activation', 'active', 'cancellation_scheduled', 'cancelled', 'expired')"

  def up do
    currency_check = "currency IN (#{quoted(@currencies)})"

    # -- Activation evidence (shared, append-only) ---------------------------------------

    create table(:billing_activation_evidence) do
      # The trusted provider module's stable name; never a credential.
      add :provider, :text, null: false
      # The provider's own reference for the verified event (no card data).
      add :provider_reference, :text, null: false
      add :subject, :text, null: false
      add :period_start, :utc_datetime_usec, null: false
      add :period_end, :utc_datetime_usec, null: false
      add :verified_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:billing_activation_evidence, [:provider, :provider_reference],
             name: :billing_activation_evidence_reference_index
           )

    create constraint(:billing_activation_evidence, :subject_values,
             check: "subject IN ('saas_subscription', 'member_product_subscription')"
           )

    create constraint(:billing_activation_evidence, :period_order,
             check: "period_end > period_start"
           )

    # -- SaaS catalog (platform) ---------------------------------------------------------

    create table(:saas_plans) do
      add :key, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:saas_plans, [:key])

    create constraint(:saas_plans, :key_format, check: "key ~ '^[a-z][a-z0-9_]{1,39}$'")

    create table(:saas_plan_versions) do
      add :plan_id, references(:saas_plans, on_delete: :nothing), null: false
      add :version, :integer, null: false
      add :name, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "draft"
      # Where its prices come from: an approved design value, an approved
      # product decision, or a provisional catalog (D-G09 reconciliation).
      add :price_source, :text, null: false
      # A proposed trial length (draft metadata only: no trial is started).
      add :proposed_trial_days, :integer
      # The approval it was published under (a decision or ticket reference).
      add :approval_reference, :text
      add :published_by, :text
      add :published_at, :utc_datetime_usec
      add :superseded_at, :utc_datetime_usec
      add :retired_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:saas_plan_versions, [:plan_id, :version])

    create unique_index(:saas_plan_versions, [:plan_id],
             where: "status = 'published'",
             name: :saas_plan_versions_published_index
           )

    create unique_index(:saas_plan_versions, [:plan_id],
             where: "status = 'draft'",
             name: :saas_plan_versions_draft_index
           )

    create constraint(:saas_plan_versions, :status_values,
             check: "status IN #{@version_statuses}"
           )

    create constraint(:saas_plan_versions, :price_source_values,
             check: "price_source IN ('approved_design', 'product_decision', 'provisional')"
           )

    create constraint(:saas_plan_versions, :version_positive, check: "version > 0")

    create constraint(:saas_plan_versions, :trial_days_range,
             check: "proposed_trial_days IS NULL OR proposed_trial_days BETWEEN 1 AND 90"
           )

    create constraint(:saas_plan_versions, :publication,
             check:
               "(status IN ('published', 'superseded', 'retired')) = (published_at IS NOT NULL) AND " <>
                 "(published_at IS NULL OR (approval_reference IS NOT NULL AND published_by IS NOT NULL))"
           )

    create table(:saas_price_versions) do
      add :plan_version_id, references(:saas_plan_versions, on_delete: :nothing), null: false
      add :interval, :text, null: false
      add :currency, :string, size: 3, null: false
      add :pricing, :text, null: false
      add :amount_minor, :bigint
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:saas_price_versions, [:plan_version_id, :interval, :currency])

    create unique_index(:saas_price_versions, [:id, :plan_version_id],
             name: :saas_price_versions_identity_index
           )

    create constraint(:saas_price_versions, :interval_values,
             check: "interval IN ('month', 'year')"
           )

    create constraint(:saas_price_versions, :currency_values, check: currency_check)

    create constraint(:saas_price_versions, :pricing_values,
             check:
               "(pricing = 'fixed' AND amount_minor IS NOT NULL AND amount_minor >= 0) OR " <>
                 "(pricing = 'quote_required' AND amount_minor IS NULL)"
           )

    create table(:saas_plan_entitlements) do
      add :plan_version_id, references(:saas_plan_versions, on_delete: :nothing), null: false
      add :feature_key, :text, null: false
      # An explicit quantity where approved; NULL is "included" (no limit stated).
      add :quantity_limit, :integer
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:saas_plan_entitlements, [:plan_version_id, :feature_key])

    create constraint(:saas_plan_entitlements, :feature_key_format,
             check: "feature_key ~ '^[a-z][a-z0-9_.]{2,63}$'"
           )

    create constraint(:saas_plan_entitlements, :quantity_positive,
             check: "quantity_limit IS NULL OR quantity_limit > 0"
           )

    create table(:billing_audit_events) do
      add :event_type, :text, null: false
      # The operator who ran the catalog workflow (a name, never a credential).
      add :actor, :text, null: false
      add :plan_id, :binary_id
      add :plan_version_id, :binary_id
      add :approval_reference, :text
      add :price_count, :integer
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:billing_audit_events, [:plan_id, :occurred_at])

    create constraint(:billing_audit_events, :event_type_values,
             check:
               "event_type IN ('saas_plan_created', 'saas_plan_version_drafted', " <>
                 "'saas_plan_version_updated', 'saas_plan_version_archived', " <>
                 "'saas_plan_version_restored', 'saas_plan_version_published', " <>
                 "'saas_plan_version_retired', 'saas_price_versions_set')"
           )

    # -- Gym SaaS subscriptions ----------------------------------------------------------

    create table(:gym_saas_subscriptions) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :plan_version_id, references(:saas_plan_versions, on_delete: :nothing), null: false

      add :price_version_id,
          references(:saas_price_versions,
            with: [plan_version_id: :plan_version_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :status, :text, null: false, default: "pending_activation"
      add :client_request_id, :binary_id, null: false
      add :requested_by_user_id, references(:users, on_delete: :nilify_all)
      add :requested_at, :utc_datetime_usec, null: false
      add :activation_evidence_id, references(:billing_activation_evidence, on_delete: :nothing)
      add :activated_at, :utc_datetime_usec
      add :current_period_start, :utc_datetime_usec
      add :current_period_end, :utc_datetime_usec
      add :cancel_mode, :text
      add :cancel_reason, :text
      add :cancellation_requested_at, :utc_datetime_usec
      add :cancellation_effective_at, :utc_datetime_usec
      add :cancelled_by_user_id, references(:users, on_delete: :nilify_all)
      add :ended_at, :utc_datetime_usec
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_saas_subscriptions, [:gym_id, :id],
             name: :gym_saas_subscriptions_gym_id_id_index
           )

    create unique_index(:gym_saas_subscriptions, [:gym_id, :client_request_id],
             name: :gym_saas_subscriptions_request_index
           )

    create unique_index(:gym_saas_subscriptions, [:gym_id],
             where: "status IN ('pending_activation', 'active', 'cancellation_scheduled')",
             name: :gym_saas_subscriptions_current_index
           )

    create unique_index(:gym_saas_subscriptions, [:activation_evidence_id],
             name: :gym_saas_subscriptions_evidence_index
           )

    create index(:gym_saas_subscriptions, [:gym_id, :requested_at, :id])

    subscription_checks(:gym_saas_subscriptions, "requested_by_gym")

    create table(:gym_saas_subscription_periods) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :subscription_id,
          references(:gym_saas_subscriptions,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :period_start, :utc_datetime_usec, null: false
      add :period_end, :utc_datetime_usec, null: false
      add :source, :text, null: false

      add :activation_evidence_id, references(:billing_activation_evidence, on_delete: :nothing),
        null: false

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:gym_saas_subscription_periods, [:subscription_id, :period_start])

    create constraint(:gym_saas_subscription_periods, :period_order,
             check: "period_end > period_start"
           )

    create constraint(:gym_saas_subscription_periods, :source_values,
             check: "source IN ('activation', 'renewal')"
           )

    # -- Gym commerce: member products -------------------------------------------------

    create table(:gym_member_products) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :product_type, :text, null: false
      add :status, :text, null: false, default: "active"
      add :client_request_id, :binary_id, null: false
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :retired_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_member_products, [:gym_id, :id],
             name: :gym_member_products_gym_id_id_index
           )

    create unique_index(:gym_member_products, [:gym_id, :key])
    create unique_index(:gym_member_products, [:gym_id, :client_request_id])

    create constraint(:gym_member_products, :key_format, check: "key ~ '^[a-z][a-z0-9_]{1,39}$'")

    create constraint(:gym_member_products, :product_type_values,
             check: "product_type IN ('single_visit', 'class_pack', 'unlimited_period')"
           )

    create constraint(:gym_member_products, :status_values,
             check:
               "status IN ('active', 'retired') AND (status = 'retired') = (retired_at IS NOT NULL)"
           )

    create table(:gym_member_product_versions) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :product_id,
          references(:gym_member_products,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :version, :integer, null: false
      add :name, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "draft"
      # Class admissions the product grants (single visit: 1; pack: N; unlimited: NULL).
      add :class_credits, :integer
      # How long it is valid once activated (days), where the type needs it.
      add :validity_days, :integer
      add :published_by_user_id, references(:users, on_delete: :nilify_all)
      add :published_at, :utc_datetime_usec
      add :superseded_at, :utc_datetime_usec
      add :retired_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_member_product_versions, [:gym_id, :id],
             name: :gym_member_product_versions_gym_id_id_index
           )

    create unique_index(:gym_member_product_versions, [:product_id, :version])

    create unique_index(:gym_member_product_versions, [:product_id],
             where: "status = 'published'",
             name: :gym_member_product_versions_published_index
           )

    create unique_index(:gym_member_product_versions, [:product_id],
             where: "status = 'draft'",
             name: :gym_member_product_versions_draft_index
           )

    create constraint(:gym_member_product_versions, :status_values,
             check: "status IN #{@version_statuses}"
           )

    create constraint(:gym_member_product_versions, :version_positive, check: "version > 0")

    create constraint(:gym_member_product_versions, :quantities,
             check:
               "(class_credits IS NULL OR class_credits BETWEEN 1 AND 500) AND " <>
                 "(validity_days IS NULL OR validity_days BETWEEN 1 AND 730)"
           )

    create constraint(:gym_member_product_versions, :publication,
             check:
               "(status IN ('published', 'superseded', 'retired')) = (published_at IS NOT NULL)"
           )

    create table(:gym_member_price_versions) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :product_version_id,
          references(:gym_member_product_versions,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :currency, :string, size: 3, null: false
      add :amount_minor, :bigint, null: false
      # 1, 2, ... per product version and currency: the latest is current.
      add :sequence, :integer, null: false
      add :client_request_id, :binary_id, null: false
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:gym_member_price_versions, [:gym_id, :id],
             name: :gym_member_price_versions_gym_id_id_index
           )

    create unique_index(:gym_member_price_versions, [:id, :product_version_id],
             name: :gym_member_price_versions_identity_index
           )

    create unique_index(:gym_member_price_versions, [:product_version_id, :currency, :sequence])
    create unique_index(:gym_member_price_versions, [:gym_id, :client_request_id])

    create constraint(:gym_member_price_versions, :currency_values, check: currency_check)

    create constraint(:gym_member_price_versions, :amount_non_negative,
             check: "amount_minor >= 0 AND sequence > 0"
           )

    create table(:gym_member_product_subscriptions) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :gym_member_id,
          references(:gym_members, with: [gym_id: :gym_id], match: :full, on_delete: :nothing),
          null: false

      add :product_version_id,
          references(:gym_member_product_versions,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :price_version_id,
          references(:gym_member_price_versions,
            with: [product_version_id: :product_version_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :status, :text, null: false, default: "pending_activation"
      add :client_request_id, :binary_id, null: false
      add :requested_by_user_id, references(:users, on_delete: :nilify_all)
      add :requested_at, :utc_datetime_usec, null: false
      add :activation_evidence_id, references(:billing_activation_evidence, on_delete: :nothing)
      add :activated_at, :utc_datetime_usec
      add :current_period_start, :utc_datetime_usec
      add :current_period_end, :utc_datetime_usec
      add :cancel_mode, :text
      add :cancel_reason, :text
      add :cancellation_requested_at, :utc_datetime_usec
      add :cancellation_effective_at, :utc_datetime_usec
      add :cancelled_by_user_id, references(:users, on_delete: :nilify_all)
      add :ended_at, :utc_datetime_usec
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_member_product_subscriptions, [:gym_id, :id],
             name: :gym_member_product_subscriptions_gym_id_id_index
           )

    create unique_index(:gym_member_product_subscriptions, [:gym_id, :client_request_id],
             name: :gym_member_product_subscriptions_request_index
           )

    create unique_index(:gym_member_product_subscriptions, [:activation_evidence_id],
             name: :gym_member_product_subscriptions_evidence_index
           )

    create index(:gym_member_product_subscriptions, [:gym_member_id, :requested_at, :id])
    create index(:gym_member_product_subscriptions, [:gym_id, :requested_at, :id])

    subscription_checks(:gym_member_product_subscriptions, "requested_by_member")

    # -- Guards ----------------------------------------------------------------------------

    version_guard(:saas_plan_versions, "saas_plan_versions_guard", [
      "plan_id",
      "version",
      "name",
      "description",
      "price_source",
      "proposed_trial_days"
    ])

    version_guard(:gym_member_product_versions, "gym_member_product_versions_guard", [
      "gym_id",
      "product_id",
      "version",
      "name",
      "description",
      "class_credits",
      "validity_days"
    ])

    # SaaS prices and entitlements belong to a draft: written, replaced or
    # removed only while their version is a draft; never updated in place.
    for table <- ~w(saas_price_versions saas_plan_entitlements) do
      execute("""
      CREATE FUNCTION #{table}_guard() RETURNS trigger AS $$
      DECLARE
        parent_status text;
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          RAISE EXCEPTION '#{table} rows are immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_immutable';
        END IF;
        -- Test cleanup of committed catalog rows only (the SF-95 purge switch).
        IF TG_OP = 'DELETE' AND
           coalesce(current_setting('simple_fit.allow_gym_member_purge', true), '') = 'on' THEN
          RETURN OLD;
        END IF;
        SELECT status INTO parent_status FROM saas_plan_versions
          WHERE id = (CASE WHEN TG_OP = 'DELETE' THEN OLD.plan_version_id ELSE NEW.plan_version_id END)
          FOR SHARE;
        IF parent_status IS DISTINCT FROM 'draft' THEN
          RAISE EXCEPTION 'only a draft plan version changes its prices or entitlements'
            USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_draft_only';
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql
      """)

      execute("""
      CREATE TRIGGER #{table}_guard BEFORE INSERT OR UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{table}_guard()
      """)
    end

    # A gym price version is appended to a draft or published product version
    # (never to a superseded, retired or archived one) and never changed.
    execute("""
    CREATE FUNCTION gym_member_price_versions_guard() RETURNS trigger AS $$
    DECLARE
      parent_status text;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'gym member price versions are immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_price_versions_immutable';
      END IF;
      SELECT status INTO parent_status FROM gym_member_product_versions
        WHERE id = NEW.product_version_id FOR SHARE;
      IF parent_status NOT IN ('draft', 'published') THEN
        RAISE EXCEPTION 'prices are added to a draft or published product version only'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_price_versions_open_version';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_member_price_versions_guard BEFORE INSERT OR UPDATE ON gym_member_price_versions
    FOR EACH ROW EXECUTE FUNCTION gym_member_price_versions_guard()
    """)

    # A SaaS subscription intent references a published, priced (not quote) version.
    execute("""
    CREATE FUNCTION gym_saas_subscriptions_offer_guard() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM saas_price_versions p JOIN saas_plan_versions v ON v.id = p.plan_version_id
        WHERE p.id = NEW.price_version_id AND v.status = 'published' AND p.pricing = 'fixed'
      ) THEN
        RAISE EXCEPTION 'a subscription needs a published, priced plan version'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_saas_subscriptions_offer';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_saas_subscriptions_offer_guard BEFORE INSERT ON gym_saas_subscriptions
    FOR EACH ROW EXECUTE FUNCTION gym_saas_subscriptions_offer_guard()
    """)

    # A member product subscription: an active member, a published version of
    # an active product.
    execute("""
    CREATE FUNCTION gym_member_product_subscriptions_offer_guard() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM gym_member_product_versions v JOIN gym_member_products p ON p.id = v.product_id
        WHERE v.id = NEW.product_version_id AND v.status = 'published' AND p.status = 'active'
      ) THEN
        RAISE EXCEPTION 'a member subscription needs a published version of an active product'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_product_subscriptions_offer';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM gym_members m WHERE m.id = NEW.gym_member_id AND m.status = 'active' FOR SHARE
      ) THEN
        RAISE EXCEPTION 'only an active member subscribes'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_member_product_subscriptions_member_active';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_member_product_subscriptions_offer_guard
    BEFORE INSERT ON gym_member_product_subscriptions
    FOR EACH ROW EXECUTE FUNCTION gym_member_product_subscriptions_offer_guard()
    """)

    for table <- ~w(gym_saas_subscriptions gym_member_product_subscriptions) do
      subscription_guard(table)
    end

    # Append-only records: never updated; deleted only by the SF-95 purge
    # switch (test cleanup of whole gyms).
    for table <-
          ~w(billing_activation_evidence gym_saas_subscription_periods) do
      execute("""
      CREATE FUNCTION #{table}_guard() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          RAISE EXCEPTION '#{table} rows are immutable'
            USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_immutable';
        END IF;
        IF coalesce(current_setting('simple_fit.allow_gym_member_purge', true), '') <> 'on' THEN
          RAISE EXCEPTION '#{table} rows are never deleted'
            USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_no_delete';
        END IF;
        RETURN OLD;
      END
      $$ LANGUAGE plpgsql
      """)

      execute("""
      CREATE TRIGGER #{table}_guard BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{table}_guard()
      """)
    end

    for table <-
          ~w(gym_saas_subscriptions gym_member_products gym_member_product_versions
             gym_member_price_versions gym_member_product_subscriptions) do
      execute("""
      CREATE TRIGGER #{table}_guard_delete BEFORE DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION gym_schedule_guard_delete()
      """)
    end

    # Platform catalog history: published versions are never deleted (drafts may be).
    execute("""
    CREATE FUNCTION saas_plan_versions_guard_delete() RETURNS trigger AS $$
    BEGIN
      IF OLD.status <> 'draft' AND OLD.status <> 'archived' AND
         coalesce(current_setting('simple_fit.allow_gym_member_purge', true), '') <> 'on' THEN
        RAISE EXCEPTION 'published plan versions are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'saas_plan_versions_no_delete';
      END IF;
      RETURN OLD;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER saas_plan_versions_guard_delete BEFORE DELETE ON saas_plan_versions
    FOR EACH ROW EXECUTE FUNCTION saas_plan_versions_guard_delete()
    """)

    # -- Gym audit -------------------------------------------------------------------------

    alter table(:gym_audit_events) do
      add :saas_subscription_id, :binary_id
      add :member_product_id, :binary_id
      add :member_product_version_id, :binary_id
      add :member_price_version_id, :binary_id
      add :member_product_subscription_id, :binary_id
    end

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@previous ++ @new)})"
           )
  end

  def down do
    execute("DELETE FROM gym_audit_events WHERE event_type IN (#{quoted(@new)})")
    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@previous)})"
           )

    alter table(:gym_audit_events) do
      remove :saas_subscription_id
      remove :member_product_id
      remove :member_product_version_id
      remove :member_price_version_id
      remove :member_product_subscription_id
    end

    drop table(:gym_member_product_subscriptions)
    drop table(:gym_member_price_versions)
    drop table(:gym_member_product_versions)
    drop table(:gym_member_products)
    drop table(:gym_saas_subscription_periods)
    drop table(:gym_saas_subscriptions)
    drop table(:billing_audit_events)
    drop table(:saas_plan_entitlements)
    drop table(:saas_price_versions)
    drop table(:saas_plan_versions)
    drop table(:saas_plans)
    drop table(:billing_activation_evidence)

    for function <-
          ~w(saas_plan_versions_guard gym_member_product_versions_guard
             saas_price_versions_guard saas_plan_entitlements_guard
             gym_member_price_versions_guard gym_saas_subscriptions_offer_guard
             gym_member_product_subscriptions_offer_guard gym_saas_subscriptions_guard
             gym_member_product_subscriptions_guard billing_activation_evidence_guard
             gym_saas_subscription_periods_guard saas_plan_versions_guard_delete) do
      execute("DROP FUNCTION IF EXISTS #{function}()")
    end
  end

  # The lifecycle columns both subscription tables share, and their checks.
  defp subscription_checks(table, intent_reason) do
    create constraint(table, :status_values, check: "status IN #{@subscription_statuses}")

    create constraint(table, :activation,
             check:
               "(status = 'pending_activation' AND activation_evidence_id IS NULL AND " <>
                 "activated_at IS NULL AND current_period_start IS NULL) OR " <>
                 "(status IN ('active', 'cancellation_scheduled') AND activation_evidence_id IS NOT NULL AND " <>
                 "activated_at IS NOT NULL AND current_period_start IS NOT NULL AND " <>
                 "current_period_end > current_period_start) OR " <>
                 "status IN ('cancelled', 'expired')"
           )

    create constraint(table, :cancellation,
             check:
               "(cancel_mode IS NULL OR cancel_mode IN ('immediate', 'period_end')) AND " <>
                 "(cancel_reason IS NULL OR cancel_reason IN ('#{intent_reason}', " <>
                 "'requested_by_staff', 'membership_ended', 'gym_closed')) AND " <>
                 "(status <> 'cancellation_scheduled' OR (cancel_mode = 'period_end' AND " <>
                 "cancellation_effective_at IS NOT NULL AND ended_at IS NULL)) AND " <>
                 "(status NOT IN ('cancelled', 'expired') OR ended_at IS NOT NULL) AND " <>
                 "(status <> 'cancelled' OR (cancel_mode IS NOT NULL AND cancellation_requested_at IS NOT NULL))"
           )
  end

  # Published contract content never changes: only the status moves forward
  # (published -> superseded or retired, superseded -> retired) with its
  # timestamp. A draft may be edited, archived and restored, or published.
  defp version_guard(table, name, fixed) do
    changed = Enum.map_join(fixed, " OR ", &"NEW.#{&1} IS DISTINCT FROM OLD.#{&1}")

    execute("""
    CREATE FUNCTION #{name}() RETURNS trigger AS $$
    BEGIN
      IF OLD.status IN ('published', 'superseded', 'retired') AND (#{changed}) THEN
        RAISE EXCEPTION 'a published version is immutable'
          USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_immutable';
      END IF;
      IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
        (OLD.status = 'draft' AND NEW.status IN ('archived', 'published')) OR
        (OLD.status = 'archived' AND NEW.status = 'draft') OR
        (OLD.status = 'published' AND NEW.status IN ('superseded', 'retired')) OR
        (OLD.status = 'superseded' AND NEW.status = 'retired')
      ) THEN
        RAISE EXCEPTION 'invalid version transition'
          USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_transition';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER #{name} BEFORE UPDATE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{name}()
    """)
  end

  # Subscription transitions: identity is fixed; pending -> active (with
  # evidence) or cancelled; active -> cancellation_scheduled, cancelled or
  # expired; cancellation_scheduled -> cancelled or expired; final states never move.
  defp subscription_guard(table) do
    execute("""
    CREATE FUNCTION #{table}_guard() RETURNS trigger AS $$
    BEGIN
      IF NEW.gym_id IS DISTINCT FROM OLD.gym_id OR
         NEW.client_request_id IS DISTINCT FROM OLD.client_request_id OR
         NEW.price_version_id IS DISTINCT FROM OLD.price_version_id OR
         NEW.requested_at IS DISTINCT FROM OLD.requested_at OR
         (OLD.activation_evidence_id IS NOT NULL AND
          NEW.activation_evidence_id IS DISTINCT FROM OLD.activation_evidence_id) THEN
        RAISE EXCEPTION 'subscription identity is fixed'
          USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_immutable';
      END IF;
      IF OLD.status IN ('cancelled', 'expired') AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'an ended subscription never changes'
          USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_final';
      END IF;
      IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
        (OLD.status = 'pending_activation' AND NEW.status IN ('active', 'cancelled')) OR
        (OLD.status = 'active' AND NEW.status IN ('cancellation_scheduled', 'cancelled', 'expired')) OR
        (OLD.status = 'cancellation_scheduled' AND NEW.status IN ('cancelled', 'expired'))
      ) THEN
        RAISE EXCEPTION 'invalid subscription transition'
          USING ERRCODE = 'check_violation', CONSTRAINT = '#{table}_transition';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER #{table}_guard BEFORE UPDATE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{table}_guard()
    """)
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
