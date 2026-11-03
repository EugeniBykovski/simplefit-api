defmodule SimpleFit.GymCommerceTest do
  @moduledoc """
  A gym's own member products and its members' product subscriptions
  (SF-101): the staff catalog (types, versions, append-only prices, RBAC,
  cross-gym isolation, database immutability), the member's intent and
  cancellation, the trusted-provider boundary, membership end, and SF-99
  bookings left unchanged. The clock is frozen (SF-62).
  """

  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BillingHelpers
  import SimpleFit.BookingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.{BillingTestProvider, Clock, Gyms, Repo}
  alias SimpleFit.Gyms.{Commerce, MemberProductSubscription}

  @now ~U[2026-01-05 12:00:00.000000Z]

  setup do
    Clock.freeze(@now)
    Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)
    owner = registered_as!(registered!("com"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    {marta, member} = member!(owner, gym.id, "Marta Kowalska")
    %{owner: owner, gym: gym, marta: marta, member: member}
  end

  defp session(user), do: live_session!(user)

  defp gym_events(gym_id, prefix) do
    gym_id
    |> audit_events()
    |> Enum.map(& &1.event_type)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), prefix))
    |> Enum.sort()
  end

  describe "catalog" do
    test "creating a product drafts its first version and price; replays; refuses a taken key",
         ctx do
      key = Ecto.UUID.generate()

      assert {:ok, {product, :created}} =
               create_product(ctx.owner, ctx.gym.id, %{
                 "client_request_id" => key,
                 "key" => "pack4"
               })

      assert product.product_type == :class_pack
      assert product.status == :active
      assert product.published == nil
      assert %{version: 1, status: :draft, class_credits: 4, validity_days: 30} = product.draft

      assert [%{currency: "PLN", amount_minor: 16_900, sequence: 1}] =
               product.draft.current_prices

      assert {:ok, {same, :existing}} =
               create_product(ctx.owner, ctx.gym.id, %{
                 "client_request_id" => key,
                 "key" => "pack4"
               })

      assert same.product_id == product.product_id

      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               create_product(ctx.owner, ctx.gym.id, %{
                 "client_request_id" => key,
                 "key" => "other"
               })

      assert {:error, {:conflict, %{member_product: "key_taken"}}} =
               create_product(ctx.owner, ctx.gym.id, %{"key" => "pack4"})

      # Nothing is offered until published.
      assert {:ok, []} = Gyms.list_my_gym_products(ctx.marta, ctx.member.gym_member_id)
      assert gym_events(ctx.gym.id, "member_product_created") == [:member_product_created]
    end

    test "type rules: single visit, class pack, unlimited period", ctx do
      assert {:ok, {single, :created}} =
               create_product(ctx.owner, ctx.gym.id, %{
                 "product_type" => "single_visit",
                 "name" => "Single Class",
                 "class_credits" => nil,
                 "validity_days" => nil,
                 "price" => %{"currency" => "PLN", "amount" => "49"}
               })

      assert single.draft.class_credits in [nil, 1]

      assert {:ok, {unlimited, :created}} =
               create_product(ctx.owner, ctx.gym.id, %{
                 "product_type" => "unlimited_period",
                 "name" => "Unlimited Monthly",
                 "class_credits" => nil,
                 "validity_days" => 30,
                 "price" => %{"currency" => "PLN", "amount" => "399.00"}
               })

      assert unlimited.draft.class_credits == nil

      for bad <- [
            %{"product_type" => "single_visit", "class_credits" => 2},
            %{"product_type" => "class_pack", "class_credits" => 1},
            %{"product_type" => "class_pack", "class_credits" => 501},
            %{"product_type" => "class_pack", "validity_days" => nil},
            %{"product_type" => "unlimited_period", "class_credits" => 8},
            %{
              "product_type" => "unlimited_period",
              "class_credits" => nil,
              "validity_days" => nil
            },
            %{"product_type" => "membership"},
            %{"validity_days" => 731},
            %{"key" => "Bad Key"},
            %{"name" => ""},
            %{"status" => "published"}
          ] do
        assert {:error, %Ecto.Changeset{}} = create_product(ctx.owner, ctx.gym.id, bad),
               "accepted #{inspect(bad)}"
      end
    end

    test "money is a decimal string in a supported currency: floats, negatives and excess precision are refused",
         ctx do
      for price <- [
            %{"currency" => "PLN", "amount" => 169.0},
            %{"currency" => "PLN", "amount" => 169},
            %{"currency" => "PLN", "amount" => "-1"},
            %{"currency" => "PLN", "amount" => "1.001"},
            %{"currency" => "XYZ", "amount" => "10"},
            %{"currency" => "PLN"},
            %{"currency" => "PLN", "amount" => "10", "vat" => "23"}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 create_product(ctx.owner, ctx.gym.id, %{"price" => price}),
               "accepted #{inspect(price)}"
      end

      assert {:ok, {free, :created}} =
               create_product(ctx.owner, ctx.gym.id, %{
                 "price" => %{"currency" => "PLN", "amount" => "0"}
               })

      assert [%{amount_minor: 0}] = free.draft.current_prices
    end

    test "publishing supersedes; prices append and become current; superseded versions refuse prices",
         ctx do
      product = published_product!(ctx.owner, ctx.gym.id)
      v1 = product.published

      add = fn version_id, attrs ->
        Gyms.add_member_product_price(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          product.product_id,
          version_id,
          Map.merge(%{"client_request_id" => Ecto.UUID.generate()}, attrs)
        )
      end

      price_key = Ecto.UUID.generate()

      assert {:ok, {repriced, :created}} =
               add.(v1.version_id, %{
                 "client_request_id" => price_key,
                 "currency" => "PLN",
                 "amount" => "179"
               })

      assert [%{amount_minor: 17_900, sequence: 2}] = repriced.published.current_prices
      assert length(repriced.published.prices) == 2

      assert {:ok, {_, :existing}} =
               add.(v1.version_id, %{
                 "client_request_id" => price_key,
                 "currency" => "PLN",
                 "amount" => "179"
               })

      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               add.(v1.version_id, %{
                 "client_request_id" => price_key,
                 "currency" => "PLN",
                 "amount" => "1"
               })

      assert {:ok, {eur, :created}} =
               add.(v1.version_id, %{"currency" => "EUR", "amount" => "39.00"})

      assert Enum.map(eur.published.current_prices, & &1.currency) == ["EUR", "PLN"]

      {:ok, with_draft} =
        Gyms.create_member_product_version(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          product.product_id,
          %{
            "client_request_id" => Ecto.UUID.generate(),
            "name" => "8-Class Pack",
            "class_credits" => 8,
            "validity_days" => 60,
            "price" => %{"currency" => "PLN", "amount" => "299"}
          }
        )

      assert {:error, {:conflict, %{member_product: "draft_exists"}}} =
               Gyms.create_member_product_version(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 product.product_id,
                 %{
                   "client_request_id" => Ecto.UUID.generate(),
                   "name" => "Again",
                   "class_credits" => 8,
                   "validity_days" => 60,
                   "price" => %{"currency" => "PLN", "amount" => "299"}
                 }
               )

      v2 = publish!(ctx.owner, ctx.gym.id, with_draft)
      assert v2.published.version == 2
      assert Enum.find(v2.versions, &(&1.version_id == v1.version_id)).status == :superseded

      assert {:error, {:conflict, %{member_product_version: "superseded"}}} =
               add.(v1.version_id, %{"currency" => "PLN", "amount" => "1"})

      assert {:error, {:conflict, %{member_product_version: "published"}}} =
               Gyms.publish_member_product_version(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 product.product_id,
                 v2.published.version_id
               )
    end

    test "the database keeps published content and prices immutable", ctx do
      product = published_product!(ctx.owner, ctx.gym.id)
      [price] = product.published.current_prices

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE gym_member_product_versions SET name = 'x' WHERE id = $1", [
          Ecto.UUID.dump!(product.published.version_id)
        ])
      end

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE gym_member_price_versions SET amount_minor = 1 WHERE id = $1", [
          Ecto.UUID.dump!(price.price_version_id)
        ])
      end

      assert_raise Postgrex.Error, fn ->
        Repo.query!("DELETE FROM gym_member_price_versions WHERE id = $1", [
          Ecto.UUID.dump!(price.price_version_id)
        ])
      end
    end

    test "retiring stops new subscriptions and keeps existing ones", ctx do
      product = published_product!(ctx.owner, ctx.gym.id)

      {:ok, {subscription, :created}} =
        request_product(ctx.marta, ctx.member.gym_member_id, product)

      {:ok, retired} =
        Gyms.retire_member_product(ctx.owner, session(ctx.owner), ctx.gym.id, product.product_id)

      assert retired.status == :retired
      assert retired.published == nil

      assert {:ok, ^retired} =
               Gyms.retire_member_product(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 product.product_id
               )

      assert {:error, {:conflict, %{member_product: "retired"}}} =
               request_product(ctx.marta, ctx.member.gym_member_id, product)

      assert {:ok, []} = Gyms.list_my_gym_products(ctx.marta, ctx.member.gym_member_id)

      assert Repo.get!(MemberProductSubscription, subscription.subscription_id).status ==
               :pending_activation
    end

    test "RBAC: owner and managers manage; front desk reads; coaches and strangers are refused",
         ctx do
      manager = registered!("com-mgr")
      staff!(ctx.gym.id, manager, :manager)
      desk = registered!("com-desk")
      staff!(ctx.gym.id, desk, :front_desk)
      coach = registered!("com-coach")
      staff!(ctx.gym.id, coach, :coach)
      stranger = registered!("com-x")

      assert {:ok, {product, :created}} = create_product(manager, ctx.gym.id, %{})
      assert {:error, :forbidden} = create_product(desk, ctx.gym.id, %{})
      assert {:error, :forbidden} = create_product(coach, ctx.gym.id, %{})
      assert {:error, :not_found} = create_product(stranger, ctx.gym.id, %{})
      # A member is not staff.
      assert {:error, :not_found} = create_product(ctx.marta, ctx.gym.id, %{})

      assert {:ok, [_]} = Gyms.list_member_products(desk, ctx.gym.id, %{})
      assert {:ok, _} = Gyms.get_member_product(desk, ctx.gym.id, product.product_id)
      assert {:ok, _} = Gyms.list_member_product_subscriptions(desk, ctx.gym.id, %{})
      assert {:error, :forbidden} = Gyms.list_member_products(coach, ctx.gym.id, %{})
      assert {:error, :forbidden} = Gyms.list_member_product_subscriptions(coach, ctx.gym.id, %{})
      assert {:error, :not_found} = Gyms.list_member_products(stranger, ctx.gym.id, %{})

      assert {:error, :forbidden} =
               Gyms.retire_member_product(desk, session(desk), ctx.gym.id, product.product_id)
    end

    test "another gym's product is a 404 everywhere", ctx do
      other_gym = completed_gym!(ctx.owner)
      product = published_product!(ctx.owner, other_gym.id)

      assert {:error, :not_found} =
               Gyms.get_member_product(ctx.owner, ctx.gym.id, product.product_id)

      assert {:error, :not_found} =
               Gyms.publish_member_product_version(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 product.product_id,
                 product.published.version_id
               )

      assert {:error, :not_found} =
               Gyms.retire_member_product(
                 ctx.owner,
                 session(ctx.owner),
                 ctx.gym.id,
                 product.product_id
               )

      # A member of this gym cannot ask for the other gym's product.
      assert {:error, :not_found} = request_product(ctx.marta, ctx.member.gym_member_id, product)
    end
  end

  describe "member subscriptions" do
    test "an intent is pending, grants nothing, replays, and is listed for the member and staff",
         ctx do
      product = published_product!(ctx.owner, ctx.gym.id)
      key = Ecto.UUID.generate()

      assert {:ok, [offer]} = Gyms.list_my_gym_products(ctx.marta, ctx.member.gym_member_id)
      assert offer.published.version_id == product.published.version_id
      refute Map.has_key?(offer, :versions)

      assert {:ok, {intent, :created}} =
               request_product(ctx.marta, ctx.member.gym_member_id, product, key)

      assert intent.status == :pending_activation
      assert intent.activated_at == nil
      assert intent.price.amount_minor == 16_900

      assert {:ok, {same, :existing}} =
               request_product(ctx.marta, ctx.member.gym_member_id, product, key)

      assert same.subscription_id == intent.subscription_id

      assert {:ok, %{entries: [mine], next_cursor: nil}} =
               Gyms.list_my_product_subscriptions(ctx.marta, %{})

      assert mine.subscription_id == intent.subscription_id
      refute Map.has_key?(mine, :member_name)

      assert {:ok, %{entries: [staff_view]}} =
               Gyms.list_member_product_subscriptions(ctx.owner, ctx.gym.id, %{})

      assert staff_view.member_name == "Marta K."

      assert {:ok, %{entries: []}} =
               Gyms.list_member_product_subscriptions(ctx.owner, ctx.gym.id, %{
                 "status" => "active"
               })

      assert gym_events(ctx.gym.id, "member_product_subscription") == [
               :member_product_subscription_requested
             ]
    end

    test "a superseded price, an unpublished version, unknown fields and others' memberships are refused",
         ctx do
      product = published_product!(ctx.owner, ctx.gym.id)
      [old_price] = product.published.current_prices

      {:ok, {_, :created}} =
        Gyms.add_member_product_price(
          ctx.owner,
          session(ctx.owner),
          ctx.gym.id,
          product.product_id,
          product.published.version_id,
          %{"client_request_id" => Ecto.UUID.generate(), "currency" => "PLN", "amount" => "189"}
        )

      request = fn user, member_id, attrs ->
        Gyms.request_member_product_subscription(
          user,
          session(user),
          member_id,
          Map.merge(
            %{
              "product_version_id" => product.published.version_id,
              "price_version_id" => old_price.price_version_id,
              "client_request_id" => Ecto.UUID.generate()
            },
            attrs
          )
        )
      end

      assert {:error, {:conflict, %{member_price_version: "superseded"}}} =
               request.(ctx.marta, ctx.member.gym_member_id, %{})

      for field <- ["status", "receipt", "payment", "credits_remaining"] do
        assert {:error, %Ecto.Changeset{}} =
                 request.(ctx.marta, ctx.member.gym_member_id, %{field => "x"})
      end

      draft = product!(ctx.owner, ctx.gym.id)

      assert {:error, {:conflict, %{member_product_version: "draft"}}} =
               request.(ctx.marta, ctx.member.gym_member_id, %{
                 "product_version_id" => draft.draft.version_id,
                 "price_version_id" => hd(draft.draft.current_prices).price_version_id
               })

      stranger = registered!("com-y")
      assert {:error, :not_found} = request.(stranger, ctx.member.gym_member_id, %{})

      assert {:error, :not_found} =
               Gyms.list_my_gym_products(stranger, ctx.member.gym_member_id)

      # A staff membership is not a gym membership: the owner has no member id here.
      assert Repo.aggregate(
               from(s in MemberProductSubscription, where: s.gym_id == ^ctx.gym.id),
               :count
             ) == 0
    end

    test "cancelling is immediate and idempotent; nothing is refunded", ctx do
      product = published_product!(ctx.owner, ctx.gym.id)
      {:ok, {intent, :created}} = request_product(ctx.marta, ctx.member.gym_member_id, product)

      cancel = fn ->
        Gyms.cancel_my_product_subscription(ctx.marta, session(ctx.marta), intent.subscription_id)
      end

      assert {:ok, %{status: :cancelled, cancel_reason: :requested_by_member}} = cancel.()
      assert {:ok, %{status: :cancelled}} = cancel.()

      assert {:error, :not_found} =
               Gyms.cancel_my_product_subscription(
                 ctx.owner,
                 session(ctx.owner),
                 intent.subscription_id
               )

      assert gym_events(ctx.gym.id, "member_product_subscription_cancelled") == [
               :member_product_subscription_cancelled
             ]
    end

    test "activation needs a trusted provider and an active member", ctx do
      product = published_product!(ctx.owner, ctx.gym.id)
      {:ok, {intent, :created}} = request_product(ctx.marta, ctx.member.gym_member_id, product)
      payload = evidence(@now, DateTime.add(@now, 30, :day))

      assert {:error, :untrusted_provider} =
               Commerce.activate_subscription(intent.subscription_id, __MODULE__, payload)

      assert {:ok, active} =
               Commerce.activate_subscription(
                 intent.subscription_id,
                 BillingTestProvider,
                 payload
               )

      assert active.status == :active
      assert active.activation_evidence_id

      assert {:error, {:conflict, %{member_product_subscription: "active"}}} =
               Commerce.activate_subscription(
                 intent.subscription_id,
                 BillingTestProvider,
                 payload
               )
    end

    test "an ending membership cancels its product subscriptions (membership_ended)", ctx do
      product = published_product!(ctx.owner, ctx.gym.id)
      {:ok, {intent, :created}} = request_product(ctx.marta, ctx.member.gym_member_id, product)

      {:ok, _} =
        Gyms.leave_gym_membership(ctx.marta, session(ctx.marta), ctx.member.gym_member_id)

      stored = Repo.get!(MemberProductSubscription, intent.subscription_id)
      assert stored.status == :cancelled
      assert stored.cancel_reason == :membership_ended

      assert {:error, {:conflict, %{gym_member: "ended"}}} =
               request_product(ctx.marta, ctx.member.gym_member_id, product)
    end

    test "booking is unchanged: no product is needed, and an intent debits nothing", ctx do
      class = class!(ctx.owner, ctx.gym.id, "2026-01-05T19:00:00+01:00", 5)

      assert %{status: :confirmed} =
               book!(ctx.marta, ctx.member.gym_member_id, class.occurrence_id)

      product = published_product!(ctx.owner, ctx.gym.id)
      {:ok, {intent, :created}} = request_product(ctx.marta, ctx.member.gym_member_id, product)

      {pawel, pawel_member} = member!(ctx.owner, ctx.gym.id, "Paweł Nowak")
      assert %{status: :confirmed} = book!(pawel, pawel_member.gym_member_id, class.occurrence_id)

      assert Repo.get!(MemberProductSubscription, intent.subscription_id).status ==
               :pending_activation
    end
  end
end
