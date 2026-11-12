defmodule SimpleFitWeb.AdminBillingControllerTest do
  @moduledoc """
  SF-127 over HTTP, checked against OpenAPI: operator billing oversight. Who may read
  what (`billing.read`, `billing.reconciliation.read`, nothing for product roles or other
  operator permissions, nothing after revocation); every figure from records the SF-101
  and SF-102 domains wrote (through the deterministic Stripe fake, never the network);
  one Stripe mode per answer with live and test rows never mixed and currencies never
  summed together; historical plan versions kept; reconciliation states only from a
  real read; canaries proving Stripe ids, hosted URLs and payloads never leave; every
  list and detail audited; and no write route at all.

  Live-mode rows can't be produced through the domain outside a production build
  (live mode is refused), so they are inserted as recorded rows that satisfy every
  database constraint.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers
  import SimpleFit.OperatorHelpers
  import SimpleFit.StripeHelpers

  alias SimpleFit.{Accounts, Operators, Repo, StripeFake}
  alias SimpleFit.Billing.{GymSubscription, Webhooks}
  alias SimpleFit.Billing.Stripe.{Invoice, SubscriptionLink}
  alias SimpleFit.Operators.AuditEvent
  alias SimpleFitWeb.ApiSpec

  @admin "/api/v1/admin/billing"

  setup do
    StripeFake.start!()
    Repo.delete_all("rate_limit_events")
    on_exit(&untrust_ceremony_keys!/0)
    {version, _mapping} = mapped_plan!()
    %{version: version}
  end

  defp operator!(permissions) do
    user = registered!("operator")
    {:ok, credentials} = Accounts.create_session(user)
    operator = bootstrap!(user, permissions)
    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)

    %{
      user: user,
      token: credentials.access_token,
      session: credentials.session,
      operator: operator
    }
  end

  defp provisioned!(founder, permissions) do
    user = registered!("reader")
    {:ok, credentials} = Accounts.create_session(user)

    {:ok, _} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => permissions})
      )

    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)
    %{user: user, token: credentials.access_token}
  end

  defp get_json(path, token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(path)

  defp ok!(path, token, schema) do
    conn = get_json(path, token)
    body = json_response(conn, 200)
    assert_schema(body, schema, ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body
  end

  defp gym!(name) do
    owner = registered_as!(registered!("owner"), "Owner #{name}")
    %{owner: owner, gym: completed_gym!(owner, %{"name" => name})}
  end

  defp reload(%GymSubscription{id: id}), do: Repo.get!(GymSubscription, id)

  # A gym paid through Stripe test mode: active, linked, one paid invoice.
  defp paid!(version, name) do
    %{owner: owner, gym: gym} = gym!(name)
    {subscription, checkout} = open_checkout!(owner, gym.id, version)
    ids = pay_checkout!(checkout)
    %{gym: gym, owner: owner, subscription: reload(subscription), ids: ids}
  end

  # A live-mode record set for a gym: a link and a paid invoice. The domain refuses
  # live mode outside a production build, so these are recorded rows.
  defp live!(version, name, amount, currency \\ "PLN") do
    %{owner: owner, gym: gym} = gym!(name)
    subscription = pending_saas!(owner, gym.id, version)
    now = DateTime.utc_now()
    suffix = String.replace(Ecto.UUID.generate(), "-", "")

    Repo.insert!(%SubscriptionLink{
      mode: :live,
      gym_id: gym.id,
      subscription_id: subscription.id,
      stripe_subscription_id: "sub_LIVE#{suffix}",
      stripe_customer_id: "cus_LIVE#{suffix}",
      provider_status: :incomplete,
      synced_at: now
    })

    invoice!(gym.id, subscription.id, :live, amount, currency, now)
    %{gym: gym, subscription: subscription}
  end

  defp invoice!(gym_id, subscription_id, mode, amount, currency, paid_at) do
    Repo.insert!(%Invoice{
      mode: mode,
      gym_id: gym_id,
      subscription_id: subscription_id,
      stripe_invoice_id: "in_REC#{String.replace(Ecto.UUID.generate(), "-", "")}",
      status: :paid,
      payment_status: :succeeded,
      currency: currency,
      amount_due: amount,
      amount_paid: amount,
      amount_remaining: 0,
      total: amount,
      hosted_invoice_url: "https://invoice.stripe.com/i/CANARY-REC",
      paid_at: paid_at,
      provider_created_at: paid_at,
      synced_at: paid_at
    })
  end

  defp audits(action),
    do: Repo.all(from(e in AuditEvent, where: e.action == ^action, order_by: e.occurred_at))

  defp no_secrets!(body, ids) do
    json = Jason.encode!(body)

    for value <- [ids.subscription, ids.invoice, ids.payment_intent, ids.charge] do
      refute json =~ value
    end

    refute json =~ "invoice.stripe.com"
    refute json =~ "checkout.stripe.com"
    refute json =~ "cus_"
    refute json =~ "whsec_"
    refute json =~ "sk_test"
  end

  describe "who may read" do
    test "anonymous 401; product roles 404; each part needs its own permission", ctx do
      %{owner: owner} = paid!(ctx.version, "Owner Gym")
      {:ok, owner_session} = Accounts.create_session(owner)

      paths = [
        "#{@admin}/overview",
        "#{@admin}/plans",
        "#{@admin}/plans/#{ctx.version |> Repo.preload(:plan) |> Map.get(:plan) |> Map.get(:key)}",
        "#{@admin}/subscriptions",
        "#{@admin}/subscriptions/#{Ecto.UUID.generate()}",
        "#{@admin}/invoices",
        "#{@admin}/reconciliation"
      ]

      {:ok, plain} = Accounts.create_session(registered!("plain"))

      for path <- paths do
        assert build_conn() |> get(path) |> json_response(401)

        # Neither an ordinary user nor the owner of a billed gym learns anything.
        for token <- [plain.access_token, owner_session.access_token] do
          assert %{"error" => %{"code" => "not_found"}} =
                   get_json(path, token) |> json_response(404)
        end
      end

      founder = operator!(["operators.manage", "gyms.read", "system.health.read"])

      for path <- paths do
        assert %{"error" => %{"code" => "forbidden"}} =
                 get_json(path, founder.token) |> json_response(403)
      end

      reader = provisioned!(founder, ["billing.read"])
      ok!("#{@admin}/overview", reader.token, "AdminBillingOverviewResponse")
      ok!("#{@admin}/plans", reader.token, "AdminBillingPlanListResponse")
      ok!("#{@admin}/subscriptions", reader.token, "AdminBillingSubscriptionListResponse")
      ok!("#{@admin}/invoices", reader.token, "AdminBillingInvoiceListResponse")

      assert %{"error" => %{"code" => "forbidden"}} =
               get_json("#{@admin}/reconciliation", reader.token) |> json_response(403)

      reconciler = provisioned!(founder, ["billing.reconciliation.read"])
      ok!("#{@admin}/reconciliation", reconciler.token, "AdminBillingReconciliationResponse")

      for path <- paths -- ["#{@admin}/reconciliation"] do
        assert %{"error" => %{"code" => "forbidden"}} =
                 get_json(path, reconciler.token) |> json_response(403)
      end

      # Refusals are recorded; nothing about a gym leaks into them.
      assert Repo.aggregate(
               from(e in AuditEvent,
                 where: e.outcome == :refused and e.permission == "billing.read"
               ),
               :count
             ) >= 1
    end

    test "a revoked grant stops the next read", _ctx do
      founder = operator!(["operators.manage"])
      reader = provisioned!(founder, ["billing.read"])
      ok!("#{@admin}/subscriptions", reader.token, "AdminBillingSubscriptionListResponse")

      operator_id =
        Repo.one!(from(o in Operators.Operator, where: o.user_id == ^reader.user.id)).id

      {:ok, _} =
        act(founder.user, founder.session, "operator.permission.revoke", operator_id, %{
          "permission" => "billing.read"
        })

      for path <- ["#{@admin}/overview", "#{@admin}/subscriptions", "#{@admin}/invoices"] do
        assert %{"error" => %{"code" => "forbidden"}} =
                 get_json(path, reader.token) |> json_response(403)
      end
    end

    test "no write route exists: refunds, cancellations, retries, reconcile and replay are not found",
         ctx do
      %{subscription: subscription} = paid!(ctx.version, "Write Gym")
      founder = operator!(["billing.read", "billing.reconciliation.read"])

      writes = [
        {:post, "#{@admin}/invoices/#{Ecto.UUID.generate()}/refund"},
        {:post, "#{@admin}/subscriptions/#{subscription.id}/cancel"},
        {:patch, "#{@admin}/subscriptions/#{subscription.id}"},
        {:delete, "#{@admin}/subscriptions/#{subscription.id}"},
        {:post, "#{@admin}/invoices/#{Ecto.UUID.generate()}/retry"},
        {:post, "#{@admin}/reconciliation"},
        {:post, "#{@admin}/plans"},
        {:put, "#{@admin}/plans/x"},
        {:post, "#{@admin}/stripe/v1/refunds"}
      ]

      for {method, path} <- writes do
        assert %{"error" => %{"code" => "not_found"}} =
                 build_conn()
                 |> put_req_header("authorization", "Bearer " <> founder.token)
                 |> put_req_header("content-type", "application/json")
                 |> dispatch(@endpoint, method, path, "{}")
                 |> json_response(404)
      end

      assert reload(subscription).status == :active
      assert StripeFake.count("POST", "/v1/refunds") == 0
    end
  end

  describe "overview" do
    test "counts and gross collected sums of one mode, from real records; never mixed", ctx do
      a = paid!(ctx.version, "Alpha Boxing")
      b = paid!(ctx.version, "Bravo Boxing")
      failed = StripeFake.fail_renewal(b.ids.subscription)
      deliver_and_process!(StripeFake.event("invoice.payment_failed", "invoice", failed.invoice))

      %{owner: idle_owner, gym: idle_gym} = gym!("Idle Boxing")
      _unrecorded = pending_saas!(idle_owner, idle_gym.id, ctx.version)
      %{owner: open_owner, gym: open_gym} = gym!("Open Checkout Boxing")
      {_open, _checkout} = open_checkout!(open_owner, open_gym.id, ctx.version)

      # Another currency of the same mode: listed apart, never added to PLN.
      invoice!(a.gym.id, nil, :test, 4_500, "EUR", DateTime.utc_now())
      # Live records: never in a test figure, and the reverse.
      live!(ctx.version, "Live Boxing", 99_900)

      reader = operator!(["billing.read"])
      test = ok!("#{@admin}/overview", reader.token, "AdminBillingOverviewResponse")["overview"]

      assert test["mode"] == "test"
      assert test["configured_mode"] == "test"
      assert test["integration"] == "ready"

      assert test["subscriptions"] == %{
               "pending_activation" => 1,
               "active" => 2,
               "cancellation_scheduled" => 0,
               "cancelled" => 0,
               "expired" => 0
             }

      assert test["unrecorded_subscriptions"]["pending_activation"] == 1
      assert test["provider_statuses"]["active"] == 1
      assert test["provider_statuses"]["past_due"] == 1
      assert test["invoices"]["paid"] == 3
      assert test["invoices"]["open"] == 1

      assert test["payment_issues"] == %{
               "payment_failed" => 1,
               "action_required" => 0,
               "uncollectible" => 0
             }

      assert [eur, pln] = test["collected"]["currencies"]

      assert eur == %{
               "currency" => "EUR",
               "invoice_count" => 1,
               "amount_paid" => "45.00",
               "amount_paid_minor" => "4500",
               "amount_refunded" => "0.00",
               "amount_refunded_minor" => "0"
             }

      assert pln["currency"] == "PLN"
      assert pln["invoice_count"] == 2
      assert pln["amount_paid_minor"] == "29800"
      assert pln["amount_paid"] == "298.00"

      assert Enum.map(test["unavailable"], & &1["metric"]) |> Enum.sort() ==
               ~w(arr churn forecast fx_total ltv mrr net_revenue recognized_revenue)

      live = ok!("#{@admin}/overview?mode=live", reader.token, "AdminBillingOverviewResponse")
      live = live["overview"]
      assert live["mode"] == "live"
      assert live["subscriptions"]["pending_activation"] == 1
      assert live["subscriptions"]["active"] == 0
      assert live["provider_statuses"]["incomplete"] == 1
      assert live["invoices"]["paid"] == 1

      assert [%{"currency" => "PLN", "amount_paid_minor" => "99900", "invoice_count" => 1}] =
               live["collected"]["currencies"]

      # The no-provider group is the same either way and in no mode's counts.
      assert live["unrecorded_subscriptions"] == test["unrecorded_subscriptions"]

      # An unknown mode is refused, never read as some default.
      assert %{"error" => %{"code" => "validation_error"}} =
               get_json("#{@admin}/overview?mode=all", reader.token) |> json_response(422)

      # Counts only: the overview isn't recorded per load.
      assert audits("billing.overview_read") == []
    end

    test "zero is a measured zero, and nothing appears without records", _ctx do
      reader = operator!(["billing.read"])
      body = ok!("#{@admin}/overview?mode=live", reader.token, "AdminBillingOverviewResponse")
      overview = body["overview"]

      assert Enum.all?(Map.values(overview["subscriptions"]), &(&1 == 0))
      assert overview["collected"]["currencies"] == []
      assert overview["last_synced_at"] == nil
      assert overview["last_webhook_at"] == nil
      assert overview["disputes"] == []
    end

    test "duplicate, replayed and out-of-order events never inflate a figure", ctx do
      a = paid!(ctx.version, "Replay Boxing")
      event = StripeFake.event("invoice.paid", "invoice", a.ids.invoice)
      assert {:ok, :accepted} = deliver(event)
      assert {:ok, :duplicate} = deliver(event)
      :ok = process_event!(event["id"])
      :ok = process_event!(event["id"])
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", a.ids.invoice))

      deliver_and_process!(
        StripeFake.event("customer.subscription.updated", "subscription", a.ids.subscription,
          created: 1
        )
      )

      reader = operator!(["billing.read"])

      overview =
        ok!("#{@admin}/overview", reader.token, "AdminBillingOverviewResponse")["overview"]

      assert overview["invoices"]["paid"] == 1
      assert overview["subscriptions"]["active"] == 1

      assert [%{"invoice_count" => 1, "amount_paid_minor" => "14900"}] =
               overview["collected"]["currencies"]
    end
  end

  describe "plans" do
    test "every version as recorded; a subscription keeps its agreed version and price", ctx do
      a = paid!(ctx.version, "History Boxing")
      key = Repo.preload(ctx.version, :plan).plan.key

      newer =
        published_plan!(
          %{"prices" => [%{"interval" => "month", "currency" => "PLN", "amount" => "199.00"}]},
          key
        )

      reader = operator!(["billing.read"])
      plans = ok!("#{@admin}/plans", reader.token, "AdminBillingPlanListResponse")["plans"]
      plan = Enum.find(plans, &(&1["key"] == key))
      assert plan["current_version_id"] == newer.id

      assert [
               %{"version" => 2, "status" => "published"},
               %{"version" => 1, "status" => "superseded"} = v1
             ] =
               plan["versions"]

      assert [
               %{
                 "amount" => "149.00",
                 "amount_minor" => 14_900,
                 "stripe_mapped_modes" => ["test"]
               }
               | _
             ] =
               v1["prices"]

      assert v1["entitlements"] == nil

      one = ok!("#{@admin}/plans/#{key}", reader.token, "AdminBillingPlanResponse")["plan"]
      assert Enum.all?(one["versions"], &is_list(&1["entitlements"]))

      detail =
        ok!(
          "#{@admin}/subscriptions/#{a.subscription.id}",
          reader.token,
          "AdminBillingSubscriptionResponse"
        )["subscription"]

      assert detail["plan"]["version"] == 1
      assert detail["plan"]["version_status"] == "superseded"
      assert detail["price"]["amount_minor"] == 14_900

      assert %{"error" => %{"code" => "not_found"}} =
               get_json("#{@admin}/plans/no_such_plan", reader.token) |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               get_json("#{@admin}/plans/BAD-KEY", reader.token) |> json_response(404)
    end
  end

  describe "subscriptions" do
    test "one environment per page, filtered, keyset pages bound to their filters; audited",
         ctx do
      paid = for n <- 1..3, do: paid!(ctx.version, "Paid #{n}")
      %{owner: idle_owner, gym: idle_gym} = gym!("Idle")
      idle = pending_saas!(idle_owner, idle_gym.id, ctx.version)
      %{owner: open_owner, gym: open_gym} = gym!("Open")
      {open, _checkout} = open_checkout!(open_owner, open_gym.id, ctx.version)
      live = live!(ctx.version, "Live", 99_900)

      reader = operator!(["billing.read"])
      path = "#{@admin}/subscriptions"

      first = ok!("#{path}?limit=2", reader.token, "AdminBillingSubscriptionListResponse")
      assert first["mode"] == "test"
      assert length(first["subscriptions"]) == 2
      assert first["next_cursor"]

      second =
        ok!(
          "#{path}?limit=2&cursor=#{URI.encode_www_form(first["next_cursor"])}",
          reader.token,
          "AdminBillingSubscriptionListResponse"
        )

      assert second["next_cursor"] == nil
      ids = Enum.map(first["subscriptions"] ++ second["subscriptions"], & &1["id"])
      assert Enum.sort(ids) == Enum.sort([open.id | Enum.map(paid, & &1.subscription.id)])
      refute idle.id in ids
      refute live.subscription.id in ids

      open_row =
        Enum.find(second["subscriptions"] ++ first["subscriptions"], &(&1["id"] == open.id))

      assert open_row["environment"] == "test"
      assert open_row["reconciliation"]["state"] == "not_linked"
      assert open_row["provider_status"] == nil
      assert open_row["gym"] == %{"id" => open_gym.id, "name" => "Open"}

      paid_row =
        Enum.find(first["subscriptions"] ++ second["subscriptions"], &(&1["status"] == "active"))

      assert paid_row["reconciliation"]["state"] == "in_sync"
      assert paid_row["provider_status"] == "active"

      assert paid_row["price"] == %{
               "interval" => "month",
               "currency" => "PLN",
               "pricing" => "fixed",
               "amount" => "149.00",
               "amount_minor" => 14_900
             }

      none = ok!("#{path}?mode=none", reader.token, "AdminBillingSubscriptionListResponse")
      assert [%{"id" => idle_id, "environment" => "none"} = idle_row] = none["subscriptions"]
      assert idle_id == idle.id
      assert idle_row["reconciliation"]["state"] == "not_evaluated"

      live_page = ok!("#{path}?mode=live", reader.token, "AdminBillingSubscriptionListResponse")
      assert [%{"environment" => "live"}] = live_page["subscriptions"]

      active =
        ok!("#{path}?status=active", reader.token, "AdminBillingSubscriptionListResponse")

      assert length(active["subscriptions"]) == 3

      by_gym =
        ok!(
          "#{path}?gym_id=#{open_gym.id}",
          reader.token,
          "AdminBillingSubscriptionListResponse"
        )

      assert [%{"id" => open_id}] = by_gym["subscriptions"]
      assert open_id == open.id

      # A cursor is bound to its filters and its reader.
      assert %{"error" => %{"code" => "validation_error"}} =
               get_json(
                 "#{path}?status=active&cursor=#{URI.encode_www_form(first["next_cursor"])}",
                 reader.token
               )
               |> json_response(422)

      for bad <- ["mode=both", "status=paid", "limit=51", "plan_key=Bad", "gym_id=x"] do
        assert %{"error" => %{"code" => "validation_error"}} =
                 get_json("#{path}?#{bad}", reader.token) |> json_response(422)
      end

      assert [_ | _] = listed = audits("billing.subscriptions_listed")
      assert Enum.all?(listed, &(&1.target_type == "billing_subscription_list"))
    end

    test "one subscription: periods, invoices with issues, refunds and disputes; no Stripe ids or URLs",
         ctx do
      a = paid!(ctx.version, "Detail Boxing")
      failed = StripeFake.fail_renewal(a.ids.subscription)
      deliver_and_process!(StripeFake.event("invoice.payment_failed", "invoice", failed.invoice))
      refund_id = StripeFake.refund_at_stripe(a.ids.payment_intent, a.ids.charge, 4_900)
      deliver_and_process!(StripeFake.event("refund.created", "refund", refund_id))
      dispute_id = StripeFake.dispute(a.ids.payment_intent, a.ids.charge, 14_900)
      deliver_and_process!(StripeFake.event("charge.dispute.created", "dispute", dispute_id))

      reader = operator!(["billing.read"])

      body =
        ok!(
          "#{@admin}/subscriptions/#{a.subscription.id}",
          reader.token,
          "AdminBillingSubscriptionResponse"
        )

      s = body["subscription"]
      assert s["status"] == "active"
      assert s["provider_status"] == "past_due"
      assert [%{"source" => "activation"}] = s["periods"]
      assert [%{"mode" => "test", "status" => "completed"} = checkout] = s["checkouts"]
      refute Map.has_key?(checkout, "url")

      [renewal, first] = s["invoices"]
      assert renewal["issue"] == "payment_failed"
      assert renewal["status"] == "open"
      assert renewal["payment_status"] == "requires_payment_method"
      assert first["status"] == "paid"
      assert first["amount_refunded"] == "49.00"
      assert first["disputed"]

      assert [%{"origin" => "provider", "amount" => "49.00", "status" => "succeeded"}] =
               first["refunds"]

      assert [%{"amount_minor" => 14_900, "status" => "needs_response"}] = first["disputes"]

      no_secrets!(body, a.ids)
      refute Jason.encode!(body) =~ refund_id
      refute Jason.encode!(body) =~ dispute_id

      assert [event] = audits("billing.subscription_viewed")
      assert event.target_type == "billing_subscription"
      assert event.target_id == a.subscription.id

      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        assert %{"error" => %{"code" => "not_found"}} =
                 get_json("#{@admin}/subscriptions/#{id}", reader.token) |> json_response(404)
      end
    end
  end

  describe "invoices" do
    test "payment issues of one mode, newest first; a recovered payment is no longer an issue",
         ctx do
      a = paid!(ctx.version, "Invoice Boxing")
      failed = StripeFake.fail_renewal(a.ids.subscription)
      deliver_and_process!(StripeFake.event("invoice.payment_failed", "invoice", failed.invoice))
      live!(ctx.version, "Live Invoice Boxing", 99_900)

      reader = operator!(["billing.read"])
      path = "#{@admin}/invoices"

      all = ok!(path, reader.token, "AdminBillingInvoiceListResponse")
      assert all["mode"] == "test"
      assert [newest, oldest] = all["invoices"]
      assert newest["issue"] == "payment_failed"

      assert newest["next_payment_attempt_at"] == nil or
               is_binary(newest["next_payment_attempt_at"])

      assert oldest["status"] == "paid"
      assert oldest["gym"]["name"] == "Invoice Boxing"
      no_secrets!(all, a.ids)

      issues = ok!("#{path}?issue=any", reader.token, "AdminBillingInvoiceListResponse")
      assert [%{"id" => issue_id}] = issues["invoices"]
      assert issue_id == newest["id"]

      live = ok!("#{path}?mode=live", reader.token, "AdminBillingInvoiceListResponse")
      assert [%{"mode" => "live", "amount_paid_minor" => 99_900}] = live["invoices"]

      # The customer pays; Stripe's retry succeeds: the same invoice, no issue.
      StripeFake.pay_invoice(failed.invoice)
      deliver_and_process!(StripeFake.event("invoice.paid", "invoice", failed.invoice))

      assert %{"invoices" => []} =
               ok!(
                 "#{path}?issue=payment_failed",
                 reader.token,
                 "AdminBillingInvoiceListResponse"
               )

      paid =
        ok!("#{path}?status=paid&currency=PLN", reader.token, "AdminBillingInvoiceListResponse")

      assert length(paid["invoices"]) == 2

      for bad <- ["mode=none", "issue=risk", "status=refunded", "currency=pln", "cursor=forged"] do
        assert %{"error" => %{"code" => "validation_error"}} =
                 get_json("#{path}?#{bad}", reader.token) |> json_response(422)
      end

      assert length(audits("billing.invoices_listed")) >= 5
    end
  end

  describe "reconciliation" do
    test "states from real reads only; the webhook inbox without ids or payloads; audited", ctx do
      in_sync = paid!(ctx.version, "In Sync Boxing")
      stale = paid!(ctx.version, "Stale Boxing")

      Repo.update_all(
        from(l in SubscriptionLink, where: l.subscription_id == ^stale.subscription.id),
        set: [synced_at: DateTime.add(DateTime.utc_now(), -7 * 3600)]
      )

      # A paid invoice for another amount: recorded as a discrepancy, grants nothing.
      %{owner: owner, gym: gym} = gym!("Mismatch Boxing")
      {mismatch, checkout} = open_checkout!(owner, gym.id, ctx.version)
      StripeFake.complete_checkout(checkout.stripe_session_id, :paid, amount: 100)

      deliver_and_process!(
        StripeFake.event(
          "checkout.session.completed",
          "checkout.session",
          checkout.stripe_session_id
        )
      )

      assert reload(mismatch).status == :pending_activation

      %{owner: open_owner, gym: open_gym} = gym!("Waiting Boxing")
      open_checkout!(open_owner, open_gym.id, ctx.version)

      # An event that ran out of retries.
      lost = StripeFake.event("invoice.paid", "invoice", in_sync.ids.invoice)
      {:ok, :accepted} = deliver(lost)
      :ok = Webhooks.give_up(SimpleFit.StripeHelpers.inbox(lost["id"]).id)

      live!(ctx.version, "Live Recon Boxing", 99_900)

      reader = operator!(["billing.reconciliation.read"])

      body =
        ok!("#{@admin}/reconciliation", reader.token, "AdminBillingReconciliationResponse")

      r = body["reconciliation"]
      assert r["mode"] == "test"

      assert %{"linked" => 3, "in_sync" => 1, "stale" => 1, "mismatch" => 1, "not_linked" => 1} =
               r["summary"]

      assert [d] = r["discrepancies"]
      assert d["subscription_id"] == mismatch.id
      assert d["discrepancy"] == "invoice_amount_mismatch"
      assert d["gym"]["name"] == "Mismatch Boxing"

      assert r["webhooks"]["counts"]["failed"] == 1

      assert [%{"event_type" => "invoice.paid", "outcome" => "retries_exhausted"}] =
               r["webhooks"]["failed"]

      json = Jason.encode!(body)
      refute json =~ lost["id"]
      refute json =~ in_sync.ids.invoice
      no_secrets!(body, in_sync.ids)

      live =
        ok!(
          "#{@admin}/reconciliation?mode=live",
          reader.token,
          "AdminBillingReconciliationResponse"
        )

      assert %{"linked" => 1, "mismatch" => 0} = live["reconciliation"]["summary"]
      assert live["reconciliation"]["webhooks"]["counts"]["failed"] == 0

      assert length(audits("billing.reconciliation_read")) == 2

      assert %{"error" => %{"code" => "validation_error"}} =
               get_json("#{@admin}/reconciliation?mode=none", reader.token) |> json_response(422)
    end

    test "nothing read means nothing reconciled: no link is never in sync", ctx do
      %{owner: owner, gym: gym} = gym!("Never Read Boxing")
      pending_saas!(owner, gym.id, ctx.version)
      reader = operator!(["billing.reconciliation.read"])
      r = ok!("#{@admin}/reconciliation", reader.token, "AdminBillingReconciliationResponse")

      assert %{"linked" => 0, "in_sync" => 0, "last_synced_at" => nil} =
               r["reconciliation"]["summary"]
    end
  end
end
