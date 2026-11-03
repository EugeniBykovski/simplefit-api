defmodule SimpleFit.StripeBillingTest do
  @moduledoc """
  SF-102 Stripe-backed SaaS billing against the deterministic Stripe fake:
  price mapping, idempotent hosted checkout (including a lost answer),
  activation only from a verified paid invoice, SCA and failed first
  payments, renewals and failed renewals, provider-side cancellation and its
  withdrawal, cancellation synchronized with Stripe, duplicate, replayed and
  out-of-order events, forged or foreign objects, refunds and disputes, and
  the disabled and live-mode guards. Entitlements are checked through the
  SF-101 projection, which stays unenforced.
  """

  use SimpleFit.DataCase, async: false
  use Oban.Testing, repo: SimpleFit.Repo

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers
  import SimpleFit.StripeHelpers

  alias SimpleFit.{Billing, Entitlements, Repo, StripeFake}

  alias SimpleFit.Billing.{
    ActivationEvidence,
    GymSubscription,
    Operations,
    Reconciliation,
    Subscriptions,
    Webhooks
  }

  alias SimpleFit.Billing.Stripe.{
    Checkout,
    Customer,
    Dispute,
    Invoice,
    PriceMapping,
    Refund,
    Signature,
    SubscriptionLink
  }

  alias SimpleFit.Gyms.AuditEvent

  setup do
    StripeFake.start!()
    Repo.delete_all("rate_limit_events")
    owner = registered_as!(registered!("stripe-owner"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    {version, mapping} = mapped_plan!()
    %{owner: owner, gym: gym, version: version, mapping: mapping}
  end

  defp reload(%GymSubscription{id: id}), do: Repo.get!(GymSubscription, id)
  defp link(subscription), do: Repo.get_by(SubscriptionLink, subscription_id: subscription.id)

  defp events(gym_id, type),
    do:
      Repo.aggregate(
        from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type),
        :count
      )

  defp in_force?(gym_id, now \\ DateTime.utc_now()),
    do: match?({:entitled, _}, Entitlements.gym_feature(gym_id, "gym.member_management", now))

  describe "price mapping" do
    test "maps a price version once per mode with Stripe's confirmed amount, currency and interval",
         ctx do
      assert %PriceMapping{mode: :test, amount_minor: 14_900, currency: "PLN", interval: :month} =
               ctx.mapping

      assert {:ok, same} = Operations.map_price(ctx.mapping.price_version_id, "ops")
      assert same.id == ctx.mapping.id
      assert StripeFake.count("POST", "/v1/prices") == 1
    end

    test "refuses quote-only prices and Stripe answers that disagree", _ctx do
      enterprise =
        draft_plan!(%{
          "prices" => [
            %{"interval" => "month", "currency" => "PLN", "pricing" => "quote_required"}
          ]
        })

      [quote] = enterprise.prices

      assert {:error, {:conflict, %{saas_price_version: "quote_required"}}} =
               Operations.map_price(quote.id, "ops")

      assert {:error, :not_found} = Operations.map_price(Ecto.UUID.generate(), "ops")
    end

    test "live mode never maps a draft or provisional price", _ctx do
      draft = draft_plan!(%{"price_source" => "provisional"})

      with_stripe(
        [mode: :live, secret_key: "sk_live_notarealkey", live_approval: "REL-1"],
        fn ->
          assert {:error, {:conflict, %{saas_plan_version: "draft"}}} =
                   Operations.map_price(price(draft).id, "ops")
        end
      )

      assert StripeFake.count("POST", "/v1/prices") == 1
    end
  end

  describe "checkout" do
    test "creates one hosted session per intent; a retry returns the open one", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)

      assert %Checkout{status: :open, url: "https://checkout.stripe.com/" <> _} = checkout
      assert {:ok, {again, :existing}} = checkout(ctx.owner, ctx.gym.id, subscription.id)
      assert again.id == checkout.id
      assert StripeFake.count("POST", "/v1/checkout/sessions") == 1
      assert StripeFake.count("POST", "/v1/customers") == 1

      [{_, _, params}] =
        Enum.filter(StripeFake.requests(), &match?({"POST", "/v1/checkout/sessions", _}, &1))

      assert params["mode"] == "subscription"
      assert params["line_items"]["0"]["price"] == ctx.mapping.stripe_price_id
      assert params["client_reference_id"] == subscription.id
      refute Map.has_key?(params, "payment_method_types")
      assert events(ctx.gym.id, :saas_checkout_started) == 1
      assert reload(subscription).status == :pending_activation
    end

    test "a lost answer is retried with the same idempotency key: one Stripe session", ctx do
      subscription = pending_saas!(ctx.owner, ctx.gym.id, ctx.version)
      StripeFake.fail_next("POST", "/v1/checkout/sessions", :lost)

      assert {:error, :timeout} = checkout(ctx.owner, ctx.gym.id, subscription.id)
      assert [%Checkout{status: :creating}] = Repo.all(Checkout)

      assert {:ok, {checkout, :created}} = checkout(ctx.owner, ctx.gym.id, subscription.id)
      assert checkout.status == :open
      assert Repo.aggregate(Checkout, :count) == 1

      sessions =
        StripeFake.requests()
        |> Enum.filter(&match?({"POST", "/v1/checkout/sessions", _}, &1))

      assert length(sessions) == 2
      assert StripeFake.get(checkout.stripe_session_id)

      assert Enum.count(
               Map.keys(Agent.get(Process.get(StripeFake), & &1.objects)),
               &String.starts_with?(&1, "cs_")
             ) == 1
    end

    test "a Stripe outage changes nothing payable", ctx do
      subscription = pending_saas!(ctx.owner, ctx.gym.id, ctx.version)
      StripeFake.fail_next("POST", "/v1/checkout/sessions", :server_error)
      assert {:error, :unavailable} = checkout(ctx.owner, ctx.gym.id, subscription.id)
      assert reload(subscription).status == :pending_activation
      assert {:ok, {_, :created}} = checkout(ctx.owner, ctx.gym.id, subscription.id)
    end

    test "refuses non-pending, unmapped or mismatched prices and a disabled provider", ctx do
      other = published_plan!()
      unmapped = pending_saas!(ctx.owner, ctx.gym.id, other)

      assert {:error, {:conflict, %{stripe_price: "not_mapped"}}} =
               checkout(ctx.owner, ctx.gym.id, unmapped.id)

      {:ok, _} =
        Billing.cancel_gym_subscription(
          ctx.owner,
          live_session!(ctx.owner),
          ctx.gym.id,
          unmapped.id,
          %{"mode" => "immediate"}
        )

      assert {:error, {:conflict, %{saas_subscription: "cancelled"}}} =
               checkout(ctx.owner, ctx.gym.id, unmapped.id)

      subscription = pending_saas!(ctx.owner, ctx.gym.id, ctx.version)

      with_stripe([enabled: false], fn ->
        assert {:error, {:conflict, %{payment_provider: "disabled"}}} =
                 checkout(ctx.owner, ctx.gym.id, subscription.id)
      end)

      assert Repo.aggregate(Checkout, :count) == 0
    end

    test "only the owner starts a checkout; other staff 403, strangers 404", ctx do
      subscription = pending_saas!(ctx.owner, ctx.gym.id, ctx.version)
      manager = registered!("stripe-mgr")
      staff!(ctx.gym.id, manager, :manager)
      stranger = registered!("stripe-x")

      assert {:error, :forbidden} = checkout(manager, ctx.gym.id, subscription.id)
      assert {:error, :not_found} = checkout(stranger, ctx.gym.id, subscription.id)
      assert {:error, :forbidden} = Billing.gym_billing_summary(manager, ctx.gym.id)
      assert {:error, :forbidden} = Billing.list_gym_invoices(manager, ctx.gym.id)
    end
  end

  describe "activation" do
    test "only the reconciled paid invoice activates; checkout completion alone does not", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      refute in_force?(ctx.gym.id)

      # Stripe completes the session but SimpleFit has not reconciled yet.
      ids = StripeFake.complete_checkout(checkout.stripe_session_id)
      assert reload(subscription).status == :pending_activation

      # A forged invoice.paid naming the real invoice re-reads Stripe: fine.
      deliver_and_process!(
        StripeFake.event(
          "checkout.session.completed",
          "checkout.session",
          checkout.stripe_session_id
        )
      )

      active = reload(subscription)
      assert active.status == :active
      assert active.activation_evidence_id

      assert %ActivationEvidence{
               provider: "SimpleFit.Billing.Stripe.Provider",
               provider_reference: ref
             } =
               Repo.get!(ActivationEvidence, active.activation_evidence_id)

      assert ref == "test:" <> ids.invoice

      assert %SubscriptionLink{provider_status: :active, stripe_subscription_id: sub_id} =
               link(subscription)

      assert sub_id == ids.subscription
      assert [%Invoice{status: :paid, total: 14_900, currency: "PLN"}] = Repo.all(Invoice)
      assert Repo.get!(Checkout, checkout.id).status == :completed
      assert in_force?(ctx.gym.id)
      assert events(ctx.gym.id, :saas_subscription_activated) == 1

      # Entitlements remain informational: no feature is enforced.
      {:ok, projection} = Entitlements.gym_projection(ctx.owner, ctx.gym.id)
      assert Enum.all?(projection.features, &(&1.enforced == false))
    end

    test "duplicate and replayed events change nothing twice", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = StripeFake.complete_checkout(checkout.stripe_session_id)
      event = StripeFake.event("invoice.paid", "invoice", ids.invoice)

      assert {:ok, :accepted} = deliver(event)
      assert {:ok, :duplicate} = deliver(event)
      assert inbox_count(event["id"]) == 1
      assert :ok = process_event!(event["id"])
      assert :ok = process_event!(event["id"])

      # Another event object about the same change.
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", ids.invoice))

      deliver_and_process!(
        StripeFake.event("customer.subscription.updated", "subscription", ids.subscription)
      )

      assert reload(subscription).status == :active
      assert Repo.aggregate(ActivationEvidence, :count) == 1
      assert events(ctx.gym.id, :saas_subscription_activated) == 1
      assert inbox(event["id"]).status == :processed
    end

    test "SCA: payment pending shows action required; paying afterwards activates", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = pay_checkout!(checkout, :action_required)

      assert reload(subscription).status == :pending_activation
      {:ok, summary} = Billing.gym_billing_summary(ctx.owner, ctx.gym.id)
      assert summary.payment.state == :action_required
      assert summary.payment.action_url == "https://invoice.stripe.com/i/" <> ids.invoice
      refute in_force?(ctx.gym.id)

      StripeFake.pay_invoice(ids.invoice)
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", ids.invoice))
      assert reload(subscription).status == :active
    end

    test "a failed first payment grants nothing and is audited once", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = pay_checkout!(checkout, :failed)
      deliver_and_process!(StripeFake.event("invoice.payment_failed", "invoice", ids.invoice))

      assert reload(subscription).status == :pending_activation
      {:ok, summary} = Billing.gym_billing_summary(ctx.owner, ctx.gym.id)
      assert summary.payment.state == :payment_failed
      assert events(ctx.gym.id, :saas_payment_failed) == 1

      # Stripe gives up on the first invoice: the intent ends.
      StripeFake.put(ids.subscription, %{"status" => "incomplete_expired"})

      deliver_and_process!(
        StripeFake.event("customer.subscription.updated", "subscription", ids.subscription)
      )

      assert %{status: :cancelled, cancel_reason: :provider_initiated} = reload(subscription)
    end

    test "an invoice for another amount or currency never activates (discrepancy)", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      StripeFake.complete_checkout(checkout.stripe_session_id, :paid, amount: 100)

      deliver_and_process!(
        StripeFake.event(
          "checkout.session.completed",
          "checkout.session",
          checkout.stripe_session_id
        )
      )

      assert reload(subscription).status == :pending_activation
      assert link(subscription).discrepancy == "invoice_amount_mismatch"
      refute in_force?(ctx.gym.id)
    end

    test "a subscription on another price never activates", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = StripeFake.complete_checkout(checkout.stripe_session_id)
      sub = StripeFake.get(ids.subscription)
      [item] = sub["items"]["data"]

      StripeFake.put(ids.subscription, %{
        "items" => %{"data" => [put_in(item, ["price", "id"], "price_forged")]}
      })

      deliver_and_process!(
        StripeFake.event(
          "checkout.session.completed",
          "checkout.session",
          checkout.stripe_session_id
        )
      )

      assert reload(subscription).status == :pending_activation
      assert link(subscription).discrepancy == "price_mismatch"
    end
  end

  describe "ownership" do
    test "events about another customer, another gym's invoice or an unknown object are ignored",
         ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = pay_checkout!(checkout)

      # A second gym with its own customer.
      other_owner = registered_as!(registered!("stripe-other"), "Ola Nowak")
      other_gym = completed_gym!(other_owner)
      {_other_sub, other_checkout} = open_checkout!(other_owner, other_gym.id, ctx.version)
      other_ids = StripeFake.complete_checkout(other_checkout.stripe_session_id)

      # The other gym's invoice cannot touch this gym's subscription.
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", other_ids.invoice))

      assert Repo.all(
               from(i in Invoice, where: i.gym_id == ^ctx.gym.id, select: i.stripe_invoice_id)
             ) == [ids.invoice]

      # A forged customer on this gym's subscription is refused.
      StripeFake.put(ids.subscription, %{"customer" => "cus_forged"})

      deliver_and_process!(
        StripeFake.event("customer.subscription.updated", "subscription", ids.subscription)
      )

      assert link(subscription).discrepancy == "customer_mismatch"

      # An object Stripe does not know for this account (another account's).
      event = StripeFake.event("invoice.paid", "invoice", "in_another_account")
      deliver_and_process!(event)
      assert inbox(event["id"]).status == :failed

      # A subscription of an unknown customer.
      StripeFake.insert(%{
        "object" => "subscription",
        "id" => "sub_stranger",
        "status" => "active",
        "customer" => "cus_stranger",
        "livemode" => false,
        "items" => %{
          "data" => [
            %{
              "price" => %{"id" => "price_x"},
              "quantity" => 1,
              "current_period_start" => 1,
              "current_period_end" => 2
            }
          ]
        }
      })

      event = StripeFake.event("customer.subscription.created", "subscription", "sub_stranger")
      deliver_and_process!(event)
      assert %{status: :ignored, outcome: "unknown_customer"} = inbox(event["id"])
    end

    test "an object of the other mode is refused", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = StripeFake.complete_checkout(checkout.stripe_session_id)
      StripeFake.put(ids.invoice, %{"livemode" => true})

      deliver_and_process!(
        StripeFake.event(
          "checkout.session.completed",
          "checkout.session",
          checkout.stripe_session_id
        )
      )

      assert reload(subscription).status == :pending_activation
    end

    test "metadata never creates a link: a subscription naming our intent without our checkout is ignored",
         ctx do
      subscription = pending_saas!(ctx.owner, ctx.gym.id, ctx.version)

      StripeFake.insert(%{
        "object" => "subscription",
        "id" => "sub_metadata",
        "status" => "active",
        "customer" => "cus_attacker",
        "metadata" => %{"simplefit_subscription_id" => subscription.id},
        "livemode" => false,
        "items" => %{
          "data" => [
            %{
              "price" => %{"id" => ctx.mapping.stripe_price_id},
              "quantity" => 1,
              "current_period_start" => 1,
              "current_period_end" => 2
            }
          ]
        }
      })

      deliver_and_process!(
        StripeFake.event("customer.subscription.created", "subscription", "sub_metadata")
      )

      assert reload(subscription).status == :pending_activation
      assert link(subscription) == nil
    end
  end

  describe "renewals and failures" do
    setup ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = pay_checkout!(checkout)
      %{subscription: reload(subscription), ids: ids}
    end

    test "a paid renewal extends the period with a renewal row", ctx do
      first_end = ctx.subscription.current_period_end
      renewal = StripeFake.renew(ctx.ids.subscription)
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", renewal.invoice))

      renewed = reload(ctx.subscription)
      assert renewed.status == :active
      assert DateTime.compare(renewed.current_period_start, first_end) == :eq
      assert DateTime.compare(renewed.current_period_end, first_end) == :gt

      assert Repo.aggregate(
               from(p in SimpleFit.Billing.SubscriptionPeriod, where: p.source == :renewal),
               :count
             ) == 1

      assert events(ctx.gym.id, :saas_subscription_renewed) == 1

      # Replays and out-of-order older events change nothing.
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", ctx.ids.invoice))
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", renewal.invoice))
      assert reload(ctx.subscription).current_period_end == renewed.current_period_end
      assert events(ctx.gym.id, :saas_subscription_renewed) == 1
    end

    test "a failed renewal is past due, keeps the paid period, then recovers", ctx do
      failed = StripeFake.fail_renewal(ctx.ids.subscription)
      deliver_and_process!(StripeFake.event("invoice.payment_failed", "invoice", failed.invoice))

      assert reload(ctx.subscription).status == :active
      {:ok, summary} = Billing.gym_billing_summary(ctx.owner, ctx.gym.id)
      assert summary.payment.state == :past_due
      assert summary.payment.next_payment_at == nil
      assert summary.payment.action_url
      assert events(ctx.gym.id, :saas_payment_failed) == 1

      # The period end does not expire a subscription still in Stripe's retries.
      assert {:ok, 0} =
               Subscriptions.advance(DateTime.add(ctx.subscription.current_period_end, 1))

      assert reload(ctx.subscription).status == :active
      refute in_force?(ctx.gym.id, DateTime.add(ctx.subscription.current_period_end, 1))

      # The customer updates the card; Stripe's retry succeeds.
      StripeFake.pay_invoice(failed.invoice)
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", failed.invoice))

      assert DateTime.compare(
               reload(ctx.subscription).current_period_end,
               ctx.subscription.current_period_end
             ) == :gt
    end

    test "Stripe ending it after failed payments expires it", ctx do
      StripeFake.fail_renewal(ctx.ids.subscription)
      StripeFake.end_subscription(ctx.ids.subscription, "payment_failed")

      deliver_and_process!(
        StripeFake.event("customer.subscription.deleted", "subscription", ctx.ids.subscription)
      )

      assert reload(ctx.subscription).status == :expired
    end

    test "out of order: an older update after the deletion keeps it cancelled", ctx do
      StripeFake.end_subscription(ctx.ids.subscription)

      deleted =
        StripeFake.event("customer.subscription.deleted", "subscription", ctx.ids.subscription)

      older =
        StripeFake.event("customer.subscription.updated", "subscription", ctx.ids.subscription,
          created: 1
        )

      deliver_and_process!(deleted)
      deliver_and_process!(older)
      assert %{status: :cancelled, cancel_reason: :provider_initiated} = reload(ctx.subscription)
    end

    test "a cancellation scheduled at Stripe, then withdrawn, reactivates", ctx do
      [item] = StripeFake.get(ctx.ids.subscription)["items"]["data"]

      StripeFake.put(ctx.ids.subscription, %{
        "cancel_at_period_end" => true,
        "cancel_at" => item["current_period_end"]
      })

      deliver_and_process!(
        StripeFake.event("customer.subscription.updated", "subscription", ctx.ids.subscription)
      )

      assert %{status: :cancellation_scheduled, cancel_reason: :provider_initiated} =
               reload(ctx.subscription)

      StripeFake.put(ctx.ids.subscription, %{"cancel_at_period_end" => false, "cancel_at" => nil})

      deliver_and_process!(
        StripeFake.event("customer.subscription.updated", "subscription", ctx.ids.subscription)
      )

      assert %{status: :active, cancel_reason: nil} = reload(ctx.subscription)
      assert events(ctx.gym.id, :saas_subscription_reactivated) == 1
    end
  end

  describe "cancellation through SimpleFit" do
    setup ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = pay_checkout!(checkout)
      %{subscription: reload(subscription), ids: ids}
    end

    defp cancel(ctx, mode),
      do:
        Billing.cancel_gym_subscription(
          ctx.owner,
          live_session!(ctx.owner),
          ctx.gym.id,
          ctx.subscription.id,
          %{"mode" => mode}
        )

    test "period_end sets cancel_at_period_end at Stripe first, then schedules", ctx do
      assert {:ok, %{status: :cancellation_scheduled, cancel_reason: :requested_by_gym}} =
               cancel(ctx, "period_end")

      assert StripeFake.get(ctx.ids.subscription)["cancel_at_period_end"] == true
      assert {:ok, %{status: :cancellation_scheduled}} = cancel(ctx, "period_end")

      # Stripe confirms; the scheduled cancellation stays the gym's.
      deliver_and_process!(
        StripeFake.event("customer.subscription.updated", "subscription", ctx.ids.subscription)
      )

      assert %{status: :cancellation_scheduled, cancel_reason: :requested_by_gym} =
               reload(ctx.subscription)

      # A paid period never refunds by itself.
      assert Repo.aggregate(Refund, :count) == 0
    end

    test "immediate cancels at Stripe (no proration) and is idempotent", ctx do
      assert {:ok, %{status: :cancelled}} = cancel(ctx, "immediate")
      assert StripeFake.get(ctx.ids.subscription)["status"] == "canceled"

      [{_, _, params}] =
        Enum.filter(StripeFake.requests(), &match?({"DELETE", "/v1/subscriptions/" <> _, _}, &1))

      assert params["prorate"] == "false"
      assert {:ok, %{status: :cancelled}} = cancel(ctx, "immediate")

      deliver_and_process!(
        StripeFake.event("customer.subscription.deleted", "subscription", ctx.ids.subscription)
      )

      assert %{status: :cancelled, cancel_reason: :requested_by_gym} = reload(ctx.subscription)
    end

    test "if Stripe cannot confirm, nothing changes locally", ctx do
      StripeFake.fail_next("POST", "/v1/subscriptions/" <> ctx.ids.subscription, :server_error)
      assert {:error, :unavailable} = cancel(ctx, "period_end")
      assert reload(ctx.subscription).status == :active

      with_stripe([enabled: false], fn ->
        assert {:error, {:conflict, %{payment_provider: "disabled"}}} = cancel(ctx, "immediate")
      end)

      assert reload(ctx.subscription).status == :active
    end
  end

  describe "pending intent cancellation" do
    test "expires the open checkout before cancelling the intent", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)

      assert {:ok, %{status: :cancelled}} =
               Billing.cancel_gym_subscription(
                 ctx.owner,
                 live_session!(ctx.owner),
                 ctx.gym.id,
                 subscription.id,
                 %{"mode" => "immediate"}
               )

      assert StripeFake.get(checkout.stripe_session_id)["status"] == "expired"
      assert Repo.get!(Checkout, checkout.id).status == :expired
    end

    test "racing a completed checkout: the payment is reconciled and the cancel is refused",
         ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      StripeFake.complete_checkout(checkout.stripe_session_id)

      assert {:error, {:conflict, %{checkout: "completed"}}} =
               Billing.cancel_gym_subscription(
                 ctx.owner,
                 live_session!(ctx.owner),
                 ctx.gym.id,
                 subscription.id,
                 %{"mode" => "immediate"}
               )

      assert reload(subscription).status == :active
    end
  end

  describe "reconcile on return and the sweep" do
    test "the return from checkout reads Stripe without a webhook", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      StripeFake.complete_checkout(checkout.stripe_session_id)

      assert {:ok, summary} =
               Billing.reconcile_gym_subscription(
                 ctx.owner,
                 live_session!(ctx.owner),
                 ctx.gym.id,
                 subscription.id
               )

      assert summary.payment.state == :active
      assert summary.payment.next_payment_at
      assert reload(subscription).status == :active
    end

    test "the sweep reconciles pending intents with a checkout", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      StripeFake.complete_checkout(checkout.stripe_session_id)
      assert :ok = perform_job(SimpleFit.Billing.Stripe.SweepWorker, %{})
      assert reload(subscription).status == :active
    end

    test "a checkout whose answer was lost past its window is marked failed", ctx do
      subscription = pending_saas!(ctx.owner, ctx.gym.id, ctx.version)
      StripeFake.fail_next("POST", "/v1/checkout/sessions", :timeout)
      {:error, :timeout} = checkout(ctx.owner, ctx.gym.id, subscription.id)
      Repo.update_all(Checkout, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])

      assert {:ok, :no_provider_subscription} =
               Reconciliation.reconcile_subscription(subscription.id)

      assert [%Checkout{status: :failed}] = Repo.all(Checkout)
    end
  end

  describe "refunds and disputes" do
    setup ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      ids = pay_checkout!(checkout)
      %{subscription: reload(subscription), ids: ids}
    end

    test "an operator full refund under an approval, once; partial refused; entitlement kept",
         ctx do
      assert {:error, {:conflict, %{refund: "partial_not_approved"}}} =
               Operations.refund(ctx.ids.invoice, "ops", "SF-102-REFUND", amount: 100)

      assert {:ok, %Refund{status: :succeeded, origin: :operator, amount_minor: 14_900}} =
               Operations.refund(ctx.ids.invoice, "ops", "SF-102-REFUND")

      assert {:error, {:conflict, %{refund: "exists"}}} =
               Operations.refund(ctx.ids.invoice, "ops", "SF-102-REFUND")

      invoice = Repo.get_by!(Invoice, stripe_invoice_id: ctx.ids.invoice)
      assert invoice.amount_refunded == 14_900
      assert events(ctx.gym.id, :saas_refund_recorded) == 1

      # The refund webhook replays change nothing.
      [refund] = Repo.all(Refund)
      deliver_and_process!(StripeFake.event("refund.updated", "refund", refund.stripe_refund_id))
      deliver_and_process!(StripeFake.event("charge.refunded", "charge", ctx.ids.charge))
      assert Repo.aggregate(Refund, :count) == 1
      assert events(ctx.gym.id, :saas_refund_recorded) == 1
      assert reload(ctx.subscription).status == :active
    end

    test "a refund whose answer was lost is retried with its key: one Stripe refund", ctx do
      StripeFake.fail_next("POST", "/v1/refunds", :lost)
      assert {:error, :timeout} = Operations.refund(ctx.ids.invoice, "ops", "SF-102-REFUND")
      assert [%Refund{status: :requested, stripe_refund_id: nil}] = Repo.all(Refund)

      assert {:ok, %Refund{status: :succeeded}} =
               Operations.refund(ctx.ids.invoice, "ops", "SF-102-REFUND")

      assert Repo.aggregate(Refund, :count) == 1

      assert Agent.get(Process.get(StripeFake), fn s ->
               s.objects |> Map.values() |> Enum.count(&(&1["object"] == "refund"))
             end) == 1
    end

    test "a refund made at Stripe is recorded truthfully (partial stays partial)", ctx do
      refund_id = StripeFake.refund_at_stripe(ctx.ids.payment_intent, ctx.ids.charge, 4_900)
      deliver_and_process!(StripeFake.event("refund.created", "refund", refund_id))

      assert [%Refund{origin: :provider, amount_minor: 4_900, status: :succeeded}] =
               Repo.all(Refund)

      assert Repo.get_by!(Invoice, stripe_invoice_id: ctx.ids.invoice).amount_refunded == 4_900
      assert reload(ctx.subscription).status == :active
    end

    test "a dispute is recorded as a dispute, never as a refund", ctx do
      dispute_id = StripeFake.dispute(ctx.ids.payment_intent, ctx.ids.charge, 14_900)
      deliver_and_process!(StripeFake.event("charge.dispute.created", "dispute", dispute_id))
      StripeFake.put(dispute_id, %{"status" => "lost"})
      deliver_and_process!(StripeFake.event("charge.dispute.closed", "dispute", dispute_id))

      assert [%Dispute{status: "lost", amount_minor: 14_900}] = Repo.all(Dispute)
      invoice = Repo.get_by!(Invoice, stripe_invoice_id: ctx.ids.invoice)
      assert invoice.disputed
      assert invoice.amount_refunded == 0
      assert Repo.aggregate(Refund, :count) == 0
      assert events(ctx.gym.id, :saas_dispute_recorded) == 1
    end
  end

  describe "webhook ingestion" do
    test "refuses bad signatures, stale timestamps, other modes and connected accounts", _ctx do
      event = StripeFake.event("invoice.paid", "invoice", "in_x")
      raw = Jason.encode!(event)

      assert {:error, :invalid_signature} = deliver(event, signature: nil)

      assert {:error, :invalid_signature} =
               deliver(event, signature: "t=1,v1=" <> String.duplicate("0", 64))

      assert {:error, :invalid_signature} =
               deliver(event, timestamp: System.os_time(:second) - 301)

      assert {:error, :invalid_signature} =
               Webhooks.ingest(
                 raw <> " ",
                 Signature.sign(
                   raw,
                   webhook_secret(),
                   System.os_time(:second)
                 ),
                 event
               )

      assert {:error, :invalid_event} =
               deliver(StripeFake.event("invoice.paid", "invoice", "in_x", livemode: true))

      assert {:error, :invalid_event} =
               deliver(StripeFake.event("invoice.paid", "invoice", "in_x", account: "acct_other"))

      assert {:error, :invalid_event} = deliver(%{"object" => "event", "id" => "nope"})
      assert Repo.aggregate(SimpleFit.Billing.Stripe.WebhookEvent, :count) == 0
    end

    test "disabled or without a secret answers disabled (retryable)", _ctx do
      event = StripeFake.event("invoice.paid", "invoice", "in_x")
      with_stripe([enabled: false], fn -> assert {:error, :disabled} = deliver(event) end)
      with_stripe([webhook_secret: nil], fn -> assert {:error, :disabled} = deliver(event) end)
    end

    test "unhandled types are recorded and ignored", _ctx do
      event = StripeFake.event("customer.created", "customer", "cus_x")
      deliver_and_process!(event)
      assert %{status: :ignored, outcome: "unhandled_type"} = inbox(event["id"])
    end

    test "a transient Stripe failure is retried by the job, then processed", ctx do
      {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
      StripeFake.complete_checkout(checkout.stripe_session_id)

      event =
        StripeFake.event(
          "checkout.session.completed",
          "checkout.session",
          checkout.stripe_session_id
        )

      {:ok, :accepted} = deliver(event)
      StripeFake.fail_next("GET", ~r{^/v1/checkout/sessions/}, :server_error)

      assert {:error, :unavailable} = process_event!(event["id"])
      assert inbox(event["id"]).status == :received
      assert :ok = process_event!(event["id"])
      assert reload(subscription).status == :active
      assert inbox(event["id"]).attempts == 2
    end
  end

  describe "portal and summary" do
    test "a portal session needs the gym's customer and the configuration", ctx do
      assert {:error, {:conflict, %{billing_portal: "no_customer"}}} =
               Billing.create_gym_portal_session(ctx.owner, live_session!(ctx.owner), ctx.gym.id)

      open_checkout!(ctx.owner, ctx.gym.id, ctx.version)

      assert {:ok, "https://billing.stripe.com/" <> _} =
               Billing.create_gym_portal_session(ctx.owner, live_session!(ctx.owner), ctx.gym.id)

      [{_, _, params}] =
        Enum.filter(
          StripeFake.requests(),
          &match?({"POST", "/v1/billing_portal/sessions", _}, &1)
        )

      assert params["configuration"] == "bpc_simplefittest"
      assert params["customer"] == Repo.one!(Customer).stripe_customer_id

      with_stripe([portal_configuration_id: nil], fn ->
        assert {:error, {:conflict, %{billing_portal: "not_configured"}}} =
                 Billing.create_gym_portal_session(
                   ctx.owner,
                   live_session!(ctx.owner),
                   ctx.gym.id
                 )
      end)
    end

    test "the summary of a gym without a subscription, and with Stripe disabled", ctx do
      assert {:ok,
              %{
                subscription: nil,
                payment: %{state: :none},
                provider: %{status: :ready, mode: :test}
              }} =
               Billing.gym_billing_summary(ctx.owner, ctx.gym.id)

      with_stripe([enabled: false], fn ->
        assert {:ok, %{provider: %{status: :disabled, mode: nil, portal_available: false}}} =
                 Billing.gym_billing_summary(ctx.owner, ctx.gym.id)
      end)
    end
  end

  defp with_stripe(overrides, fun) do
    original = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe)
    Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, Keyword.merge(original, overrides))

    try do
      fun.()
    after
      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, original)
    end
  end
end
