defmodule SimpleFitWeb.GymBillingStripeControllerTest do
  @moduledoc """
  SF-102 Stripe-backed billing over HTTP with real sessions and the
  deterministic Stripe fake: summary, invoices, hosted checkout, reconcile,
  portal and cancellation through Stripe; the webhook endpoint through the
  real endpoint pipeline (raw-body signature, 200 / 400 / 503). Every
  response is checked against the OpenAPI schemas and `no-store`; no key,
  secret, card or Stripe object id is rendered outside Stripe-hosted URLs.
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers
  import SimpleFit.StripeHelpers

  alias SimpleFit.{Accounts, RateLimit, Repo, StripeFake}
  alias SimpleFit.Billing.Stripe.{Signature, WebhookEvent}
  alias SimpleFit.Gyms.MemberSecrets
  alias SimpleFitWeb.ApiSpec

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp ok(conn, schema, status \\ 200) do
    body = json_response(conn, status)
    assert_schema(body, schema, ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  setup do
    StripeFake.start!()
    Repo.delete_all("rate_limit_events")
    owner = registered_as!(registered!("stripe-http"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    {version, _mapping} = mapped_plan!()

    %{
      owner: owner,
      gym: gym,
      version: version,
      token: token(owner),
      base: "/api/v1/gyms/#{gym.id}"
    }
  end

  defp intent!(ctx) do
    (ctx.token
     |> authed()
     |> post(
       "#{ctx.base}/saas-subscriptions",
       Jason.encode!(%{
         plan_version_id: ctx.version.id,
         price_version_id: price(ctx.version).id,
         client_request_id: Ecto.UUID.generate()
       })
     )
     |> ok("GymSaasSubscriptionResponse", 201))["subscription"]
  end

  test "intent → hosted checkout → return → reconciled active subscription and invoice", ctx do
    summary =
      ctx.token |> authed() |> get("#{ctx.base}/billing") |> ok("GymBillingSummaryResponse")

    assert %{
             "provider" => %{"status" => "ready", "mode" => "test", "portal_available" => false},
             "subscription" => nil,
             "payment" => %{"state" => "none"}
           } = summary["billing"]

    sub = intent!(ctx)
    path = "#{ctx.base}/saas-subscriptions/#{sub["subscription_id"]}"

    checkout =
      ctx.token
      |> authed()
      |> post("#{path}/checkout-session")
      |> ok("GymSaasCheckoutResponse", 201)

    assert %{"status" => "open", "url" => "https://checkout.stripe.com/" <> _} =
             checkout["checkout"]

    again =
      ctx.token |> authed() |> post("#{path}/checkout-session") |> ok("GymSaasCheckoutResponse")

    assert again["checkout"]["checkout_id"] == checkout["checkout"]["checkout_id"]

    pending =
      ctx.token |> authed() |> get("#{ctx.base}/billing") |> ok("GymBillingSummaryResponse")

    assert pending["billing"]["payment"]["state"] == "checkout_open"
    assert pending["billing"]["checkout"]["status"] == "open"

    [row] = Repo.all(SimpleFit.Billing.Stripe.Checkout)
    StripeFake.complete_checkout(row.stripe_session_id)

    reconciled =
      ctx.token |> authed() |> post("#{path}/reconcile") |> ok("GymBillingSummaryResponse")

    assert %{
             "subscription" => %{"status" => "active"},
             "payment" => %{"state" => "active", "next_payment_at" => next}
           } =
             reconciled["billing"]

    assert next

    invoices =
      ctx.token |> authed() |> get("#{ctx.base}/billing/invoices") |> ok("GymBillingInvoiceList")

    assert [
             %{
               "status" => "paid",
               "total" => "149.00",
               "total_minor" => 14_900,
               "currency" => "PLN",
               "mode" => "test",
               "hosted_invoice_url" => "https://invoice.stripe.com/" <> _,
               "disputed" => false
             }
           ] = invoices["invoices"]

    refute inspect(invoices) =~ "cus_"
    refute inspect(reconciled) =~ "sub_"

    portal =
      ctx.token
      |> authed()
      |> post("#{ctx.base}/billing/portal-session")
      |> ok("GymBillingPortalResponse", 201)

    assert "https://billing.stripe.com/" <> _ = portal["portal"]["url"]

    cancelled =
      ctx.token
      |> authed()
      |> post("#{path}/cancel", Jason.encode!(%{mode: "period_end"}))
      |> ok("GymSaasSubscriptionResponse")

    assert cancelled["subscription"]["status"] == "cancellation_scheduled"
  end

  test "RBAC: managers and front desk 403, strangers 404, anonymous 401", ctx do
    sub = intent!(ctx)
    manager = registered!("stripe-http-mgr")
    staff!(ctx.gym.id, manager, :manager)
    desk = registered!("stripe-http-desk")
    staff!(ctx.gym.id, desk, :front_desk)
    stranger = registered!("stripe-http-x")
    path = "#{ctx.base}/saas-subscriptions/#{sub["subscription_id"]}"

    for user <- [manager, desk] do
      t = token(user)
      t |> authed() |> get("#{ctx.base}/billing") |> error(403, "forbidden")
      t |> authed() |> get("#{ctx.base}/billing/invoices") |> error(403, "forbidden")
      t |> authed() |> post("#{path}/checkout-session") |> error(403, "forbidden")
      t |> authed() |> post("#{ctx.base}/billing/portal-session") |> error(403, "forbidden")
    end

    t = token(stranger)
    t |> authed() |> get("#{ctx.base}/billing") |> error(404, "not_found")
    t |> authed() |> get("#{ctx.base}/billing/invoices") |> error(404, "not_found")
    t |> authed() |> post("#{path}/checkout-session") |> error(404, "not_found")
    build_conn() |> get("#{ctx.base}/billing") |> error(401, "unauthorized")

    ctx.token
    |> authed()
    |> post("#{ctx.base}/saas-subscriptions/#{Ecto.UUID.generate()}/checkout-session")
    |> error(404, "not_found")
  end

  test "authorization comes before the provider state: a disabled provider is never disclosed",
       ctx do
    sub = intent!(ctx)
    manager = registered!("stripe-http-mgr2")
    staff!(ctx.gym.id, manager, :manager)
    stranger = registered!("stripe-http-x2")
    path = "#{ctx.base}/saas-subscriptions/#{sub["subscription_id"]}"
    original = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe)

    Application.put_env(
      :simple_fit,
      SimpleFit.Billing.Stripe,
      Keyword.put(original, :enabled, false)
    )

    try do
      for {user, status, code} <- [{manager, 403, "forbidden"}, {stranger, 404, "not_found"}] do
        t = token(user)
        t |> authed() |> post("#{path}/checkout-session") |> error(status, code)
        t |> authed() |> post("#{path}/reconcile") |> error(status, code)
        t |> authed() |> post("#{ctx.base}/billing/portal-session") |> error(status, code)
      end
    after
      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, original)
    end
  end

  test "409 when unmapped or provider disabled, 503 when Stripe is down, 429 when rate limited",
       ctx do
    sub = intent!(ctx)
    path = "#{ctx.base}/saas-subscriptions/#{sub["subscription_id"]}"

    StripeFake.fail_next("POST", "/v1/checkout/sessions", :server_error)
    ctx.token |> authed() |> post("#{path}/checkout-session") |> error(503, "service_unavailable")

    original = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe)

    Application.put_env(
      :simple_fit,
      SimpleFit.Billing.Stripe,
      Keyword.put(original, :enabled, false)
    )

    try do
      err = ctx.token |> authed() |> post("#{path}/checkout-session") |> error(409, "conflict")
      assert err["details"] == %{"payment_provider" => "disabled"}

      summary =
        ctx.token |> authed() |> get("#{ctx.base}/billing") |> ok("GymBillingSummaryResponse")

      assert summary["billing"]["provider"] == %{
               "status" => "disabled",
               "mode" => nil,
               "portal_available" => false
             }
    after
      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, original)
    end

    other = published_plan!()

    {:ok, _} =
      SimpleFit.Billing.cancel_gym_subscription(
        ctx.owner,
        live_session!(ctx.owner),
        ctx.gym.id,
        sub["subscription_id"],
        %{
          "mode" => "immediate"
        }
      )

    {:ok, {unmapped, _}} = request_saas(ctx.owner, ctx.gym.id, other, price(other))

    err =
      ctx.token
      |> authed()
      |> post("#{ctx.base}/saas-subscriptions/#{unmapped.id}/checkout-session")
      |> error(409, "conflict")

    assert err["details"] == %{"stripe_price" => "not_mapped"}

    key = MemberSecrets.rate_limit_key("user", ctx.owner.id)
    for _ <- 1..30, do: RateLimit.hit([{"gym_billing_user", key, 30, 600}])

    conn =
      ctx.token
      |> authed()
      |> post("#{ctx.base}/saas-subscriptions/#{unmapped.id}/checkout-session")

    error(conn, 429, "rate_limited")
  end

  describe "webhook endpoint" do
    defp webhook(body, signature) do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")

      conn = if signature, do: put_req_header(conn, "stripe-signature", signature), else: conn
      post(conn, "/api/webhooks/stripe", body)
    end

    test "verifies the raw body: 200 once, duplicate on replay, 400 otherwise" do
      event = StripeFake.event("customer.created", "customer", "cus_1")
      raw = Jason.encode!(event)
      signature = Signature.sign(raw, webhook_secret(), System.os_time(:second))

      body = webhook(raw, signature) |> json_response(200)
      assert body == %{"received" => true, "duplicate" => false}
      assert_schema(body, "StripeWebhookAck", ApiSpec.spec())

      assert webhook(raw, signature) |> json_response(200) == %{
               "received" => true,
               "duplicate" => true
             }

      assert Repo.aggregate(WebhookEvent, :count) == 1

      # The same JSON re-serialized differently fails: the signature is over bytes.
      pretty = Jason.encode!(event, pretty: true)
      webhook(pretty, signature) |> error(400, "bad_request")
      webhook(raw, nil) |> error(400, "bad_request")

      stale = Signature.sign(raw, webhook_secret(), System.os_time(:second) - 600)
      webhook(raw, stale) |> error(400, "bad_request")

      forged = Signature.sign(raw, "whsec_attackersecret", System.os_time(:second))
      webhook(raw, forged) |> error(400, "bad_request")

      live = Jason.encode!(StripeFake.event("invoice.paid", "invoice", "in_1", livemode: true))

      webhook(live, Signature.sign(live, webhook_secret(), System.os_time(:second)))
      |> error(400, "bad_request")
    end

    test "503 while disabled so Stripe retries later" do
      original = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe)

      Application.put_env(
        :simple_fit,
        SimpleFit.Billing.Stripe,
        Keyword.put(original, :enabled, false)
      )

      try do
        raw = Jason.encode!(StripeFake.event("invoice.paid", "invoice", "in_1"))
        conn = webhook(raw, Signature.sign(raw, webhook_secret(), System.os_time(:second)))
        error(conn, 503, "service_unavailable")
        assert get_resp_header(conn, "retry-after") == ["60"]
      after
        Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, original)
      end
    end

    test "other routes keep no raw body copy", ctx do
      conn = ctx.token |> authed() |> get("#{ctx.base}/billing")
      assert conn.private[:raw_body] == nil
    end
  end
end
