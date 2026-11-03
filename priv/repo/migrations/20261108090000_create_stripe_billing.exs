defmodule SimpleFit.Repo.Migrations.CreateStripeBilling do
  @moduledoc """
  SF-102: Stripe as the payment provider of SimpleFit's SaaS billing (ADR
  0026 amendment SF-102; ADR 0005). The SF-101 subscription domain stays the
  source of truth for gyms, plans, prices, lifecycle and entitlements; these
  tables map it to Stripe objects and record what Stripe verified. Every row
  names its Stripe mode (`test` or `live`): objects of one mode never meet
  the other.

  * `stripe_customers` - the gym's Stripe Customer (one per gym and mode).
  * `stripe_prices` - the Stripe Product/Price created for one SF-101 price
    version, with the amount, currency and interval it was created for.
    Immutable: a price version maps to exactly one Stripe Price per mode.
  * `stripe_checkouts` - a hosted Checkout Session for one pending
    subscription intent: `creating` (the request is in flight or its answer
    was lost; retried with the same idempotency key), `open`, `completed`,
    `expired` or `failed`. At most one `creating`/`open` per subscription.
  * `stripe_subscriptions` - the Stripe Subscription behind an SF-101
    subscription, with the provider status last reconciled.
  * `stripe_invoices` - Stripe invoices of a gym's customer as last
    reconciled (status, amounts in minor units, hosted URLs, refunds,
    disputes). Never computed locally.
  * `stripe_refunds`, `stripe_disputes` - refunds (operator-requested or
    seen at Stripe) and disputes of those invoices.
  * `stripe_webhook_events` - the webhook inbox: one row per verified Stripe
    event (unique per mode), ids and type only, never the payload; the
    processing outcome.
  * `stripe_connected_accounts` - the Stripe Connect foundation for gym
    member payments: an operator-linked account and its synced capability
    summary. Nothing creates a charge on it.

  The SF-101 subscription guard gains one transition, `cancellation_scheduled
  -> active` (a cancellation withdrawn at the provider), and the cancel
  reasons gain `provider_initiated` (the provider ended it outside
  SimpleFit). Financial rows are never deleted (the SF-95 purge switch of
  test cleanup excepted).
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
                   member_product_subscription_cancelled member_product_subscription_expired)

  @gym_new ~w(saas_checkout_started saas_subscription_renewed saas_subscription_reactivated
              saas_payment_failed saas_refund_recorded saas_dispute_recorded)

  @billing_previous ~w(saas_plan_created saas_plan_version_drafted saas_plan_version_updated
                       saas_plan_version_archived saas_plan_version_restored
                       saas_plan_version_published saas_plan_version_retired
                       saas_price_versions_set)

  @billing_new ~w(stripe_price_mapped stripe_refund_requested stripe_connected_account_linked)

  @modes "mode IN ('test', 'live')"

  @tables ~w(stripe_customers stripe_prices stripe_checkouts stripe_subscriptions
             stripe_invoices stripe_refunds stripe_disputes stripe_webhook_events
             stripe_connected_accounts)

  def up do
    create table(:stripe_customers) do
      add :mode, :text, null: false
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :stripe_customer_id, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:stripe_customers, [:mode, :gym_id])
    create unique_index(:stripe_customers, [:mode, :stripe_customer_id])
    create constraint(:stripe_customers, :mode_values, check: @modes)

    create constraint(:stripe_customers, :customer_format,
             check: "stripe_customer_id ~ '^cus_[A-Za-z0-9]{1,250}$'"
           )

    create table(:stripe_prices) do
      add :mode, :text, null: false
      add :price_version_id, references(:saas_price_versions, on_delete: :nothing), null: false
      add :stripe_product_id, :text, null: false
      add :stripe_price_id, :text, null: false
      add :currency, :text, null: false
      add :amount_minor, :bigint, null: false
      add :interval, :text, null: false
      # The operator who mapped it (a name, never a credential).
      add :mapped_by, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:stripe_prices, [:mode, :price_version_id])
    create unique_index(:stripe_prices, [:mode, :stripe_price_id])
    create constraint(:stripe_prices, :mode_values, check: @modes)
    create constraint(:stripe_prices, :interval_values, check: "interval IN ('month', 'year')")
    create constraint(:stripe_prices, :amount_positive, check: "amount_minor > 0")

    create constraint(:stripe_prices, :price_format,
             check: "stripe_price_id ~ '^price_[A-Za-z0-9]{1,250}$'"
           )

    create table(:stripe_checkouts) do
      add :mode, :text, null: false
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :subscription_id,
          references(:gym_saas_subscriptions,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :idempotency_key, :binary_id, null: false
      add :stripe_session_id, :text
      add :url, :text
      add :status, :text, null: false, default: "creating"
      add :expires_at, :utc_datetime_usec, null: false
      add :requested_by_user_id, references(:users, on_delete: :nilify_all)
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_checkouts, [:idempotency_key])
    create unique_index(:stripe_checkouts, [:mode, :stripe_session_id])

    create unique_index(:stripe_checkouts, [:subscription_id],
             where: "status IN ('creating', 'open')",
             name: :stripe_checkouts_current_index
           )

    create index(:stripe_checkouts, [:gym_id, :inserted_at])
    create constraint(:stripe_checkouts, :mode_values, check: @modes)

    create constraint(:stripe_checkouts, :status_values,
             check: "status IN ('creating', 'open', 'completed', 'expired', 'failed')"
           )

    create constraint(:stripe_checkouts, :session_known,
             check:
               "status IN ('creating', 'failed') OR " <>
                 "(stripe_session_id ~ '^cs_[A-Za-z0-9_]{1,250}$')"
           )

    create table(:stripe_subscriptions) do
      add :mode, :text, null: false
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :subscription_id,
          references(:gym_saas_subscriptions,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :stripe_subscription_id, :text, null: false
      add :stripe_customer_id, :text, null: false
      add :provider_status, :text, null: false
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :current_period_start, :utc_datetime_usec
      add :current_period_end, :utc_datetime_usec
      add :latest_invoice_id, :text
      # Why the provider state could not be applied (a code, never a payload).
      add :discrepancy, :text
      add :synced_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_subscriptions, [:subscription_id])
    create unique_index(:stripe_subscriptions, [:mode, :stripe_subscription_id])
    create index(:stripe_subscriptions, [:mode, :synced_at])
    create constraint(:stripe_subscriptions, :mode_values, check: @modes)

    create constraint(:stripe_subscriptions, :subscription_format,
             check: "stripe_subscription_id ~ '^sub_[A-Za-z0-9]{1,250}$'"
           )

    create constraint(:stripe_subscriptions, :provider_status_values,
             check:
               "provider_status IN ('incomplete', 'incomplete_expired', 'trialing', 'active', " <>
                 "'past_due', 'canceled', 'unpaid', 'paused')"
           )

    create table(:stripe_invoices) do
      add :mode, :text, null: false
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :subscription_id, references(:gym_saas_subscriptions, on_delete: :nothing)
      add :stripe_invoice_id, :text, null: false
      add :stripe_subscription_id, :text
      add :number, :text
      add :status, :text, null: false
      # The last payment attempt's state at the provider (no card data).
      add :payment_status, :text
      add :currency, :text, null: false
      add :amount_due, :bigint, null: false
      add :amount_paid, :bigint, null: false
      add :amount_remaining, :bigint, null: false
      add :total, :bigint, null: false
      add :amount_refunded, :bigint, null: false, default: 0
      add :disputed, :boolean, null: false, default: false
      add :billing_reason, :text
      add :period_start, :utc_datetime_usec
      add :period_end, :utc_datetime_usec
      add :hosted_invoice_url, :text
      add :invoice_pdf, :text
      add :paid_at, :utc_datetime_usec
      add :provider_created_at, :utc_datetime_usec, null: false
      add :attempt_count, :integer, null: false, default: 0
      add :next_payment_attempt_at, :utc_datetime_usec
      add :synced_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_invoices, [:mode, :stripe_invoice_id])
    create index(:stripe_invoices, [:gym_id, :mode, :provider_created_at])
    create index(:stripe_invoices, [:subscription_id])
    create constraint(:stripe_invoices, :mode_values, check: @modes)

    create constraint(:stripe_invoices, :status_values,
             check: "status IN ('draft', 'open', 'paid', 'uncollectible', 'void')"
           )

    create constraint(:stripe_invoices, :payment_status_values,
             check:
               "payment_status IS NULL OR payment_status IN ('requires_action', " <>
                 "'requires_payment_method', 'processing', 'succeeded', 'canceled')"
           )

    create constraint(:stripe_invoices, :amounts_non_negative,
             check:
               "amount_due >= 0 AND amount_paid >= 0 AND amount_remaining >= 0 AND " <>
                 "amount_refunded >= 0"
           )

    create constraint(:stripe_invoices, :invoice_format,
             check: "stripe_invoice_id ~ '^in_[A-Za-z0-9]{1,250}$'"
           )

    create table(:stripe_refunds) do
      add :mode, :text, null: false
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :invoice_id, references(:stripe_invoices, on_delete: :nothing), null: false
      add :stripe_refund_id, :text
      add :idempotency_key, :binary_id
      add :origin, :text, null: false
      add :status, :text, null: false
      add :amount_minor, :bigint, null: false
      add :currency, :text, null: false
      add :reason, :text
      # Operator requests: who asked and under which approval (names only).
      add :requested_by, :text
      add :approval_reference, :text
      add :synced_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_refunds, [:mode, :stripe_refund_id])
    create unique_index(:stripe_refunds, [:idempotency_key])
    create index(:stripe_refunds, [:invoice_id])

    # One operator refund in flight or done per invoice (full refunds only).
    create unique_index(:stripe_refunds, [:invoice_id],
             where:
               "origin = 'operator' AND status IN ('requested', 'pending', 'requires_action', " <>
                 "'succeeded')",
             name: :stripe_refunds_operator_index
           )

    create constraint(:stripe_refunds, :mode_values, check: @modes)

    create constraint(:stripe_refunds, :origin_values,
             check: "origin IN ('operator', 'provider')"
           )

    create constraint(:stripe_refunds, :status_values,
             check:
               "status IN ('requested', 'pending', 'requires_action', 'succeeded', 'failed', " <>
                 "'canceled')"
           )

    create constraint(:stripe_refunds, :amount_positive, check: "amount_minor > 0")

    create constraint(:stripe_refunds, :operator_request,
             check:
               "origin <> 'operator' OR (idempotency_key IS NOT NULL AND requested_by IS NOT NULL " <>
                 "AND approval_reference IS NOT NULL)"
           )

    create constraint(:stripe_refunds, :provider_known,
             check: "origin <> 'provider' OR stripe_refund_id IS NOT NULL"
           )

    create table(:stripe_disputes) do
      add :mode, :text, null: false
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :invoice_id, references(:stripe_invoices, on_delete: :nothing), null: false
      add :stripe_dispute_id, :text, null: false
      add :status, :text, null: false
      add :reason, :text
      add :amount_minor, :bigint, null: false
      add :currency, :text, null: false
      add :synced_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_disputes, [:mode, :stripe_dispute_id])
    create index(:stripe_disputes, [:invoice_id])
    create constraint(:stripe_disputes, :mode_values, check: @modes)

    create table(:stripe_webhook_events) do
      add :mode, :text, null: false
      add :stripe_event_id, :text, null: false
      add :event_type, :text, null: false
      add :object_type, :text
      add :object_id, :text
      add :event_created_at, :utc_datetime_usec, null: false
      add :status, :text, null: false, default: "received"
      # The processing outcome as a code (never a payload or a message).
      add :outcome, :text
      add :attempts, :integer, null: false, default: 0
      add :processed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:stripe_webhook_events, [:mode, :stripe_event_id])
    create index(:stripe_webhook_events, [:status, :inserted_at])
    create constraint(:stripe_webhook_events, :mode_values, check: @modes)

    create constraint(:stripe_webhook_events, :status_values,
             check: "status IN ('received', 'processed', 'ignored', 'failed')"
           )

    create constraint(:stripe_webhook_events, :event_format,
             check: "stripe_event_id ~ '^evt_[A-Za-z0-9_]{1,250}$'"
           )

    create table(:stripe_connected_accounts) do
      add :mode, :text, null: false
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :stripe_account_id, :text, null: false
      add :charges_enabled, :boolean, null: false, default: false
      add :payouts_enabled, :boolean, null: false, default: false
      add :details_submitted, :boolean, null: false, default: false
      add :requirements_due_count, :integer, null: false, default: 0
      add :disabled_reason, :text
      add :linked_by, :text, null: false
      add :last_synced_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_connected_accounts, [:mode, :gym_id])
    create unique_index(:stripe_connected_accounts, [:mode, :stripe_account_id])
    create constraint(:stripe_connected_accounts, :mode_values, check: @modes)

    create constraint(:stripe_connected_accounts, :account_format,
             check: "stripe_account_id ~ '^acct_[A-Za-z0-9]{1,250}$'"
           )

    # Mappings that identify a provider object never change.
    for table <- ~w(stripe_customers stripe_prices) do
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

    # The provider identity of a mapping is fixed once known.
    execute("""
    CREATE FUNCTION stripe_identity_guard() RETURNS trigger AS $$
    BEGIN
      IF NEW.mode IS DISTINCT FROM OLD.mode OR NEW.gym_id IS DISTINCT FROM OLD.gym_id THEN
        RAISE EXCEPTION 'a provider mapping keeps its mode and gym'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'stripe_identity_immutable';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    for table <- @tables -- ~w(stripe_customers stripe_prices stripe_webhook_events) do
      execute("""
      CREATE TRIGGER #{table}_identity_guard BEFORE UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION stripe_identity_guard()
      """)

      execute("""
      CREATE TRIGGER #{table}_guard_delete BEFORE DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION gym_schedule_guard_delete()
      """)
    end

    execute("""
    CREATE TRIGGER stripe_webhook_events_guard_delete BEFORE DELETE ON stripe_webhook_events
    FOR EACH ROW EXECUTE FUNCTION gym_schedule_guard_delete()
    """)

    # -- SF-101 amendments ----------------------------------------------------------------

    drop constraint(:gym_saas_subscriptions, :cancellation)
    create constraint(:gym_saas_subscriptions, :cancellation, check: cancellation_check(true))
    subscription_guard(true)

    # -- Audit ------------------------------------------------------------------------------

    alter table(:gym_audit_events) do
      # The SF-102 record an event names (a checkout, invoice, refund or dispute row).
      add :billing_record_id, :binary_id
    end

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@gym_previous ++ @gym_new)})"
           )

    alter table(:billing_audit_events) do
      add :gym_id, :binary_id
      add :billing_record_id, :binary_id
    end

    drop constraint(:billing_audit_events, :event_type_values)

    create constraint(:billing_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@billing_previous ++ @billing_new)})"
           )
  end

  def down do
    execute("DELETE FROM billing_audit_events WHERE event_type IN (#{quoted(@billing_new)})")
    drop constraint(:billing_audit_events, :event_type_values)

    create constraint(:billing_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@billing_previous)})"
           )

    alter table(:billing_audit_events) do
      remove :gym_id
      remove :billing_record_id
    end

    execute("DELETE FROM gym_audit_events WHERE event_type IN (#{quoted(@gym_new)})")
    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(@gym_previous)})"
           )

    alter table(:gym_audit_events) do
      remove :billing_record_id
    end

    # A subscription the provider ended keeps an SF-101 reason on the way down.
    execute("""
    UPDATE gym_saas_subscriptions SET cancel_reason = 'requested_by_gym'
    WHERE cancel_reason = 'provider_initiated'
    """)

    drop constraint(:gym_saas_subscriptions, :cancellation)
    create constraint(:gym_saas_subscriptions, :cancellation, check: cancellation_check(false))
    subscription_guard(false)

    for table <- ~w(stripe_connected_accounts stripe_webhook_events stripe_disputes stripe_refunds
                    stripe_invoices stripe_subscriptions stripe_checkouts stripe_prices
                    stripe_customers) do
      drop table(table)
    end

    for function <- ~w(stripe_customers_guard stripe_prices_guard stripe_identity_guard) do
      execute("DROP FUNCTION IF EXISTS #{function}()")
    end
  end

  # The SF-101 cancellation check of gym SaaS subscriptions, with or without
  # the SF-102 `provider_initiated` reason.
  defp cancellation_check(provider?) do
    reasons =
      ~w(requested_by_gym requested_by_staff membership_ended gym_closed) ++
        if(provider?, do: ["provider_initiated"], else: [])

    "(cancel_mode IS NULL OR cancel_mode IN ('immediate', 'period_end')) AND " <>
      "(cancel_reason IS NULL OR cancel_reason IN (#{quoted(reasons)})) AND " <>
      "(status <> 'cancellation_scheduled' OR (cancel_mode = 'period_end' AND " <>
      "cancellation_effective_at IS NOT NULL AND ended_at IS NULL)) AND " <>
      "(status NOT IN ('cancelled', 'expired') OR ended_at IS NOT NULL) AND " <>
      "(status <> 'cancelled' OR (cancel_mode IS NOT NULL AND cancellation_requested_at IS NOT NULL))"
  end

  # The SF-101 transition guard of gym SaaS subscriptions; SF-102 adds
  # `cancellation_scheduled -> active` (a cancellation withdrawn at the
  # provider, applied only from reconciled provider state).
  defp subscription_guard(provider?) do
    withdrawn =
      if provider?,
        do: " OR (OLD.status = 'cancellation_scheduled' AND NEW.status = 'active')",
        else: ""

    execute("""
    CREATE OR REPLACE FUNCTION gym_saas_subscriptions_guard() RETURNS trigger AS $$
    BEGIN
      IF NEW.gym_id IS DISTINCT FROM OLD.gym_id OR
         NEW.client_request_id IS DISTINCT FROM OLD.client_request_id OR
         NEW.price_version_id IS DISTINCT FROM OLD.price_version_id OR
         NEW.requested_at IS DISTINCT FROM OLD.requested_at OR
         (OLD.activation_evidence_id IS NOT NULL AND
          NEW.activation_evidence_id IS DISTINCT FROM OLD.activation_evidence_id) THEN
        RAISE EXCEPTION 'subscription identity is fixed'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_saas_subscriptions_immutable';
      END IF;
      IF OLD.status IN ('cancelled', 'expired') AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'an ended subscription never changes'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_saas_subscriptions_final';
      END IF;
      IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
        (OLD.status = 'pending_activation' AND NEW.status IN ('active', 'cancelled')) OR
        (OLD.status = 'active' AND NEW.status IN ('cancellation_scheduled', 'cancelled', 'expired')) OR
        (OLD.status = 'cancellation_scheduled' AND NEW.status IN ('cancelled', 'expired'))#{withdrawn}
      ) THEN
        RAISE EXCEPTION 'invalid subscription transition'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_saas_subscriptions_transition';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
