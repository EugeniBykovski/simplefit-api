defmodule SimpleFitWeb.GymMemberProductControllerTest do
  @moduledoc """
  Gym member products over HTTP (SF-101), with real sessions: the staff
  catalog (create, version, publish, price, retire, subscriptions) and the
  member side (offers, intent, list, cancel); every response checked against
  the OpenAPI schemas, `no-store`, and 200 / 201 / 401 / 403 / 404 / 409 /
  422 / 429. Amounts are decimal strings, never floats.
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.BookingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Clock, RateLimit}
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

  defp product_request(overrides \\ %{}) do
    Map.merge(
      %{
        client_request_id: Ecto.UUID.generate(),
        key: "pack_#{System.unique_integer([:positive])}",
        product_type: "class_pack",
        name: "4-Class Pack",
        class_credits: 4,
        validity_days: 30,
        price: %{currency: "PLN", amount: "169.00"}
      },
      overrides
    )
  end

  setup do
    Clock.freeze(@now)
    SimpleFit.Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)
    owner = registered_as!(registered!("com-http"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    {marta, member} = member!(owner, gym.id, "Marta Kowalska")

    %{
      owner: owner,
      gym: gym,
      marta: marta,
      member: member,
      token: token(owner),
      base: "/api/v1/gyms/#{gym.id}/member-products"
    }
  end

  test "staff create, publish, reprice and retire a product; a member asks for it and cancels",
       ctx do
    created =
      ctx.token
      |> authed()
      |> post(ctx.base, body(product_request()))
      |> ok("GymMemberProductResponse", 201)

    product = created["product"]
    assert %{"status" => "active", "published" => nil, "draft" => %{"version" => 1}} = product

    assert [%{"amount" => "169.00", "amount_minor" => 16_900, "currency" => "PLN"}] =
             product["draft"]["current_prices"]

    id = product["product_id"]
    draft_id = product["draft"]["version_id"]

    published =
      ctx.token
      |> authed()
      |> post("#{ctx.base}/#{id}/versions/#{draft_id}/publish")
      |> ok("GymMemberProductResponse")

    assert published["product"]["published"]["version_id"] == draft_id

    member_token = token(ctx.marta)
    me = "/api/v1/me/gym-memberships/#{ctx.member.gym_member_id}"

    offers = member_token |> authed() |> get(me <> "/products") |> ok("GymMemberOfferList")

    assert [%{"product_id" => ^id, "published" => %{"current_prices" => [price]}}] =
             offers["products"]

    refute Map.has_key?(hd(offers["products"]), "versions")

    request = %{
      product_version_id: draft_id,
      price_version_id: price["price_version_id"],
      client_request_id: Ecto.UUID.generate()
    }

    intent =
      member_token
      |> authed()
      |> post(me <> "/product-subscriptions", body(request))
      |> ok("GymMemberProductSubscriptionResponse", 201)

    sub = intent["subscription"]
    assert %{"status" => "pending_activation", "price" => %{"amount" => "169.00"}} = sub
    refute Map.has_key?(sub, "member_name")

    member_token
    |> authed()
    |> post(me <> "/product-subscriptions", body(request))
    |> ok("GymMemberProductSubscriptionResponse")

    mine =
      member_token
      |> authed()
      |> get("/api/v1/me/product-subscriptions")
      |> ok("GymMemberProductSubscriptionList")

    assert [%{"subscription_id" => sub_id}] = mine["subscriptions"]

    staff_list =
      ctx.token
      |> authed()
      |> get("/api/v1/gyms/#{ctx.gym.id}/member-product-subscriptions")
      |> ok("GymMemberProductSubscriptionList")

    assert [%{"member_name" => "Marta K.", "subscription_id" => ^sub_id}] =
             staff_list["subscriptions"]

    refute inspect(staff_list) =~ "@"

    # A new price is current for new requests; the old one is a 409.
    repriced =
      ctx.token
      |> authed()
      |> post(
        "#{ctx.base}/#{id}/versions/#{draft_id}/prices",
        body(%{client_request_id: Ecto.UUID.generate(), currency: "PLN", amount: "179.50"})
      )
      |> ok("GymMemberProductResponse", 201)

    assert [%{"amount" => "179.50", "sequence" => 2}] =
             repriced["product"]["published"]["current_prices"]

    member_token
    |> authed()
    |> post(
      me <> "/product-subscriptions",
      body(%{request | client_request_id: Ecto.UUID.generate()})
    )
    |> error(409, "conflict")
    |> then(&assert(&1["details"] == %{"member_price_version" => "superseded"}))

    cancelled =
      member_token
      |> authed()
      |> post("/api/v1/me/product-subscriptions/#{sub_id}/cancel")
      |> ok("GymMemberProductSubscriptionResponse")

    assert cancelled["subscription"]["status"] == "cancelled"

    retired =
      ctx.token |> authed() |> post("#{ctx.base}/#{id}/retire") |> ok("GymMemberProductResponse")

    assert retired["product"]["status"] == "retired"

    assert (member_token
            |> authed()
            |> get(me <> "/products")
            |> ok("GymMemberOfferList"))["products"] == []

    shown = ctx.token |> authed() |> get("#{ctx.base}/#{id}") |> ok("GymMemberProductResponse")
    assert length(shown["product"]["versions"]) == 1
    listed = ctx.token |> authed() |> get(ctx.base) |> ok("GymMemberProductList")
    assert [_] = listed["products"]
  end

  test "a second version is drafted and published; the first is superseded", ctx do
    product =
      (ctx.token
       |> authed()
       |> post(ctx.base, body(product_request()))
       |> ok("GymMemberProductResponse", 201))["product"]

    ctx.token
    |> authed()
    |> post(
      "#{ctx.base}/#{product["product_id"]}/versions/#{product["draft"]["version_id"]}/publish"
    )
    |> ok("GymMemberProductResponse")

    v2 =
      ctx.token
      |> authed()
      |> post(
        "#{ctx.base}/#{product["product_id"]}/versions",
        body(%{
          client_request_id: Ecto.UUID.generate(),
          name: "8-Class Pack",
          class_credits: 8,
          validity_days: 60,
          price: %{currency: "PLN", amount: "299"}
        })
      )
      |> ok("GymMemberProductResponse", 201)

    v2_id = v2["product"]["draft"]["version_id"]

    done =
      ctx.token
      |> authed()
      |> post("#{ctx.base}/#{product["product_id"]}/versions/#{v2_id}/publish")
      |> ok("GymMemberProductResponse")

    assert done["product"]["published"]["version"] == 2
    assert Enum.map(done["product"]["versions"], & &1["status"]) == ["published", "superseded"]

    ctx.token
    |> authed()
    |> post("#{ctx.base}/#{product["product_id"]}/versions/#{v2_id}/publish")
    |> error(409, "conflict")
  end

  test "422 for floats, negatives, unknown currencies, unknown fields and type violations", ctx do
    for overrides <- [
          %{price: %{currency: "PLN", amount: 169.0}},
          %{price: %{currency: "PLN", amount: "-5"}},
          %{price: %{currency: "PLN", amount: "1.005"}},
          %{price: %{currency: "BTC", amount: "1"}},
          %{status: "published"},
          %{product_type: "class_pack", class_credits: 1},
          %{product_type: "unlimited_period", class_credits: 10}
        ] do
      ctx.token
      |> authed()
      |> post(ctx.base, body(product_request(overrides)))
      |> error(422, "validation_error")
    end
  end

  test "RBAC: front desk reads, coach 403, stranger 404, member side only for own memberships",
       ctx do
    desk = registered!("com-http-desk")
    staff!(ctx.gym.id, desk, :front_desk)
    coach = registered!("com-http-coach")
    staff!(ctx.gym.id, coach, :coach)
    stranger = registered!("com-http-x")

    token(desk) |> authed() |> get(ctx.base) |> ok("GymMemberProductList")
    token(desk) |> authed() |> post(ctx.base, body(product_request())) |> error(403, "forbidden")
    token(coach) |> authed() |> get(ctx.base) |> error(403, "forbidden")

    token(coach)
    |> authed()
    |> get("/api/v1/gyms/#{ctx.gym.id}/member-product-subscriptions")
    |> error(403, "forbidden")

    token(stranger) |> authed() |> get(ctx.base) |> error(404, "not_found")
    build_conn() |> get(ctx.base) |> error(401, "unauthorized")

    token(stranger)
    |> authed()
    |> get("/api/v1/me/gym-memberships/#{ctx.member.gym_member_id}/products")
    |> error(404, "not_found")

    token(stranger)
    |> authed()
    |> post("/api/v1/me/product-subscriptions/#{Ecto.UUID.generate()}/cancel")
    |> error(404, "not_found")

    other = completed_gym!(ctx.owner)

    foreign =
      (ctx.token
       |> authed()
       |> post("/api/v1/gyms/#{other.id}/member-products", body(product_request()))
       |> ok("GymMemberProductResponse", 201))["product"]

    ctx.token
    |> authed()
    |> get("#{ctx.base}/#{foreign["product_id"]}")
    |> error(404, "not_found")
  end

  test "429 after 60 catalog changes per 10 minutes", ctx do
    key = MemberSecrets.rate_limit_key("user", ctx.owner.id)
    for _ <- 1..60, do: :ok = RateLimit.hit([{"gym_commerce_admin_user", key, 60, 600}])

    conn = ctx.token |> authed() |> post(ctx.base, body(product_request()))
    error(conn, 429, "rate_limited")
    assert [_] = get_resp_header(conn, "retry-after")
  end
end
