defmodule SimpleFitWeb.GymBillingControllerTest do
  @moduledoc """
  SimpleFit plans over HTTP (SF-101), with real sessions: the published
  catalog, a gym's subscription intent and cancellation, its entitlement
  projection; every response checked against the OpenAPI schemas,
  `no-store`, and 200 / 201 / 401 / 403 / 404 / 409 / 422 / 429. Amounts are
  decimal strings; no provider, approval or operator detail is exposed.
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Clock, RateLimit}
  alias SimpleFit.Billing.Catalog
  alias SimpleFit.Gyms.MemberSecrets
  alias SimpleFitWeb.ApiSpec

  @now ~U[2026-01-05 12:00:00.000000Z]

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

  defp body(map), do: Jason.encode!(map)

  setup do
    Clock.freeze(@now)
    SimpleFit.Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)
    owner = registered_as!(registered!("bill-http"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    plan = published_plan!(%{"proposed_trial_days" => 14})
    %{owner: owner, gym: gym, plan: plan, token: token(owner)}
  end

  test "the catalog lists published versions only, with decimal-string prices", ctx do
    draft_plan!()

    plans = ctx.token |> authed() |> get("/api/v1/saas-plans") |> ok("SaasPlanList")
    [plan] = Enum.filter(plans["plans"], &(&1["plan_version_id"] == ctx.plan.id))

    assert %{"name" => "Starter", "version" => 1, "proposed_trial_days" => 14} = plan

    assert [
             %{
               "interval" => "month",
               "currency" => "PLN",
               "pricing" => "fixed",
               "amount" => "149.00",
               "amount_minor" => 14_900
             },
             %{"interval" => "year", "amount" => "1490.00", "amount_minor" => 149_000}
           ] = plan["prices"]

    assert plan["entitlements"] == [
             %{"feature_key" => "gym.member_management", "quantity_limit" => nil}
           ]

    refute Map.has_key?(plan, "approval_reference")
    refute Map.has_key?(plan, "published_by")
    assert Enum.all?(plans["plans"], &(&1["plan_version_id"] != nil))

    build_conn() |> get("/api/v1/saas-plans") |> error(401, "unauthorized")
  end

  test "the owner records an intent, replays it, lists it and cancels it", ctx do
    path = "/api/v1/gyms/#{ctx.gym.id}/saas-subscriptions"
    key = Ecto.UUID.generate()

    request = %{
      plan_version_id: ctx.plan.id,
      price_version_id: price(ctx.plan).id,
      client_request_id: key
    }

    created =
      ctx.token |> authed() |> post(path, body(request)) |> ok("GymSaasSubscriptionResponse", 201)

    sub = created["subscription"]

    assert %{
             "status" => "pending_activation",
             "activated_at" => nil,
             "current_period_end" => nil,
             "plan" => %{"name" => "Starter", "version" => 1},
             "price" => %{"amount" => "149.00", "currency" => "PLN", "interval" => "month"}
           } = sub

    refute Map.has_key?(sub, "activation_evidence_id")

    replay =
      ctx.token |> authed() |> post(path, body(request)) |> ok("GymSaasSubscriptionResponse")

    assert replay["subscription"]["subscription_id"] == sub["subscription_id"]

    ctx.token
    |> authed()
    |> post(path, body(%{request | client_request_id: Ecto.UUID.generate()}))
    |> error(409, "conflict")
    |> then(&assert(&1["details"] == %{"saas_subscription" => "current_exists"}))

    list = ctx.token |> authed() |> get(path) |> ok("GymSaasSubscriptionList")
    assert [%{"subscription_id" => id}] = list["subscriptions"]
    assert id == sub["subscription_id"]

    entitlements =
      ctx.token
      |> authed()
      |> get("/api/v1/gyms/#{ctx.gym.id}/entitlements")
      |> ok("GymEntitlements")

    assert entitlements["subscription"] == %{
             "subscription_id" => id,
             "status" => "pending_activation",
             "in_force" => false
           }

    assert Enum.all?(
             entitlements["features"],
             &(&1["status"] == "denied" and &1["enforced"] == false)
           )

    assert Enum.all?(entitlements["features"], &(&1["reason"] == "pending_activation"))

    cancelled =
      ctx.token
      |> authed()
      |> post("#{path}/#{id}/cancel", body(%{mode: "period_end"}))
      |> ok("GymSaasSubscriptionResponse")

    assert %{
             "status" => "cancelled",
             "cancel_mode" => "immediate",
             "cancel_reason" => "requested_by_gym"
           } =
             cancelled["subscription"]

    ctx.token
    |> authed()
    |> post("#{path}/#{id}/cancel", body(%{mode: "immediate"}))
    |> ok("GymSaasSubscriptionResponse")
  end

  test "422: a client cannot activate or pay; invalid ids and modes are refused", ctx do
    path = "/api/v1/gyms/#{ctx.gym.id}/saas-subscriptions"

    base = %{
      plan_version_id: ctx.plan.id,
      price_version_id: price(ctx.plan).id,
      client_request_id: Ecto.UUID.generate()
    }

    for extra <- [%{status: "active"}, %{receipt: "fake"}, %{payment_token: "tok_x"}] do
      ctx.token
      |> authed()
      |> post(path, body(Map.merge(base, extra)))
      |> error(422, "validation_error")
    end

    ctx.token
    |> authed()
    |> post(path, body(%{base | plan_version_id: "nope"}))
    |> error(422, "validation_error")

    ctx.token
    |> authed()
    |> get(path)
    |> ok("GymSaasSubscriptionList")
    |> then(&assert(&1["subscriptions"] == []))

    sub = pending_saas!(ctx.owner, ctx.gym.id, ctx.plan)

    ctx.token
    |> authed()
    |> post("#{path}/#{sub.id}/cancel", body(%{mode: "whenever"}))
    |> error(422, "validation_error")
  end

  test "403 for other staff, 404 for strangers and other gyms, 409 for a retired version", ctx do
    path = "/api/v1/gyms/#{ctx.gym.id}/saas-subscriptions"
    manager = registered!("bill-http-mgr")
    staff!(ctx.gym.id, manager, :manager)
    stranger = registered!("bill-http-x")

    request =
      body(%{
        plan_version_id: ctx.plan.id,
        price_version_id: price(ctx.plan).id,
        client_request_id: Ecto.UUID.generate()
      })

    token(manager) |> authed() |> post(path, request) |> error(403, "forbidden")
    token(manager) |> authed() |> get(path) |> error(403, "forbidden")

    token(manager)
    |> authed()
    |> get("/api/v1/gyms/#{ctx.gym.id}/entitlements")
    |> ok("GymEntitlements")

    token(stranger) |> authed() |> post(path, request) |> error(404, "not_found")

    token(stranger)
    |> authed()
    |> get("/api/v1/gyms/#{ctx.gym.id}/entitlements")
    |> error(404, "not_found")

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, request)
    |> error(401, "unauthorized")

    other = completed_gym!(ctx.owner)
    sub = pending_saas!(ctx.owner, other.id, ctx.plan)

    ctx.token
    |> authed()
    |> post("#{path}/#{sub.id}/cancel", body(%{mode: "immediate"}))
    |> error(404, "not_found")

    {:ok, _} = Catalog.retire(ctx.plan.id, operator())

    ctx.token
    |> authed()
    |> post(path, request)
    |> error(409, "conflict")
    |> then(&assert(&1["details"] == %{"saas_plan_version" => "retired"}))
  end

  test "429 after 30 billing changes per 10 minutes", ctx do
    key = MemberSecrets.rate_limit_key("user", ctx.owner.id)
    for _ <- 1..30, do: :ok = RateLimit.hit([{"gym_billing_user", key, 30, 600}])

    conn =
      ctx.token
      |> authed()
      |> post(
        "/api/v1/gyms/#{ctx.gym.id}/saas-subscriptions",
        body(%{
          plan_version_id: ctx.plan.id,
          price_version_id: price(ctx.plan).id,
          client_request_id: Ecto.UUID.generate()
        })
      )

    error(conn, 429, "rate_limited")
    assert [_] = get_resp_header(conn, "retry-after")
  end

  test "an activated subscription projects its entitlements over HTTP", ctx do
    active = active_saas!(ctx.owner, ctx.gym.id, ctx.plan, @now, ~U[2026-02-05 12:00:00.000000Z])

    body =
      ctx.token
      |> authed()
      |> get("/api/v1/gyms/#{ctx.gym.id}/entitlements")
      |> ok("GymEntitlements")

    assert body["subscription"]["in_force"] == true
    assert body["subscription"]["subscription_id"] == active.id

    assert %{"status" => "entitled", "reason" => nil} =
             Enum.find(body["features"], &(&1["key"] == "gym.member_management"))

    assert %{"status" => "denied", "reason" => "not_in_plan"} =
             Enum.find(body["features"], &(&1["key"] == "gym.timetable"))

    list =
      ctx.token
      |> authed()
      |> get("/api/v1/gyms/#{ctx.gym.id}/saas-subscriptions")
      |> ok("GymSaasSubscriptionList")

    [sub] = list["subscriptions"]
    assert sub["status"] == "active"
    assert sub["current_period_end"] == "2026-02-05T12:00:00.000000Z"
    refute inspect(sub) =~ "ref_"
  end
end
