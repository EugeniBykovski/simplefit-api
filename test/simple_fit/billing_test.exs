defmodule SimpleFit.BillingTest do
  @moduledoc """
  SimpleFit SaaS plans (SF-101): the operator catalog (drafts, provisional
  seed, publication under an approval, immutability in the database), a
  gym's subscription intent and lifecycle with the test-only trusted
  provider, the payment boundary, and fail-closed entitlements. The clock is
  frozen (SF-62).
  """

  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.{Billing, Clock, Entitlements, Gyms, Repo}
  alias SimpleFit.Billing.{Activation, AuditEvent, Catalog, GymSubscription, Subscriptions}
  alias SimpleFit.Entitlements.Features

  @now ~U[2026-01-05 12:00:00.000000Z]
  @period_end ~U[2026-02-05 12:00:00.000000Z]

  setup do
    Clock.freeze(@now)
    Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)
    owner = registered_as!(registered!("bill"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym}
  end

  defp events(gym_id, prefix) do
    gym_id
    |> audit_events()
    |> Enum.map(& &1.event_type)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), prefix))
    # Events of one frozen instant share `occurred_at`: compared as a multiset.
    |> Enum.sort()
  end

  describe "catalog" do
    test "the provisional seed writes drafts only, never offered, and is idempotent" do
      Repo.delete_all(from(p in "saas_plans", where: p.key in ~w(starter growth pro enterprise)))
      |> then(fn _ -> :ok end)

      assert {:ok, ~w(starter growth pro enterprise)} = Catalog.seed_provisional(operator())
      assert {:ok, []} = Catalog.seed_provisional(operator())

      assert Billing.published_plans() == []

      [starter] = Catalog.versions("starter")
      assert starter.status == :draft
      assert starter.price_source == :provisional
      assert starter.proposed_trial_days == 14
      assert starter.entitlements == []

      assert [
               %{interval: :month, amount_minor: 14_900},
               %{interval: :year, amount_minor: 149_000}
             ] =
               Enum.map(starter.prices, &Map.take(&1, [:interval, :amount_minor]))

      assert Enum.all?(starter.prices, &(&1.currency == "PLN" and &1.pricing == :fixed))

      [growth] = Catalog.versions("growth")
      [pro] = Catalog.versions("pro")
      assert Enum.map(growth.prices, & &1.amount_minor) == [34_900, 349_000]
      assert Enum.map(pro.prices, & &1.amount_minor) == [69_900, 699_000]

      [enterprise] = Catalog.versions("enterprise")

      assert Enum.all?(
               enterprise.prices,
               &(&1.pricing == :quote_required and is_nil(&1.amount_minor))
             )

      assert enterprise.proposed_trial_days == nil
    end

    test "publication needs an approval, prices and, for provisional prices, an explicit confirmation" do
      provisional = draft_plan!(%{"price_source" => "provisional"})

      assert {:error, {:conflict, %{saas_plan_version: "approval_required"}}} =
               Catalog.publish(provisional.id, "  ", operator())

      assert {:error, {:conflict, %{saas_plan_version: "provisional_confirmation_required"}}} =
               Catalog.publish(provisional.id, "SF-101", operator())

      assert {:ok, published} =
               Catalog.publish(provisional.id, "SF-101", operator(), confirm_provisional: true)

      assert published.status == :published
      assert published.approval_reference == "SF-101"
      assert published.published_by == operator()

      unpriced = draft_plan!(%{"prices" => []})

      assert {:error, {:conflict, %{saas_plan_version: "no_prices"}}} =
               Catalog.publish(unpriced.id, "SF-101", operator())
    end

    test "a newer published version supersedes the old one, which keeps its content and subscriptions",
         ctx do
      key = plan_key()
      v1 = published_plan!(%{}, key)
      subscription = pending_saas!(ctx.owner, ctx.gym.id, v1)

      v2 =
        draft_plan!(
          %{
            "name" => "Starter 2",
            "prices" => [%{"interval" => "month", "currency" => "PLN", "amount" => "199"}]
          },
          key
        )

      assert v2.version == 2
      {:ok, v2} = Catalog.publish(v2.id, "SF-101-B", operator())

      {:ok, old} = Catalog.get_version(v1.id)
      assert old.status == :superseded
      assert old.name == "Starter"
      assert Enum.map(old.prices, & &1.amount_minor) == [14_900, 149_000]
      assert Repo.get!(GymSubscription, subscription.id).price_version_id == price(v1).id
      assert [%{id: id}] = Enum.filter(Billing.published_plans(), &(&1.plan.key == key))
      assert id == v2.id
    end

    test "one draft per plan; drafts are edited, archived and restored; unknown features are refused" do
      key = plan_key()
      draft = draft_plan!(%{}, key)

      assert {:error, {:conflict, %{saas_plan: "draft_exists"}}} =
               Catalog.draft(key, plan_attrs(), operator())

      {:ok, updated} =
        Catalog.update_draft(draft.id, plan_attrs(%{"name" => "Renamed"}), operator())

      assert updated.name == "Renamed"
      {:ok, archived} = Catalog.archive(draft.id, operator())
      assert archived.status == :archived
      {:ok, restored} = Catalog.restore(draft.id, operator())
      assert restored.status == :draft

      assert {:error, %Ecto.Changeset{}} =
               Catalog.update_draft(
                 draft.id,
                 plan_attrs(%{"entitlements" => [%{"feature_key" => "gym.teleport"}]}),
                 operator()
               )

      assert {:error, %Ecto.Changeset{}} =
               Catalog.update_draft(
                 draft.id,
                 plan_attrs(%{
                   "prices" => [%{"interval" => "month", "currency" => "PLN", "amount" => 149.0}]
                 }),
                 operator()
               )

      assert {:error, %Ecto.Changeset{}} = Catalog.draft("Bad Key", plan_attrs(), operator())

      events =
        Repo.all(
          from(e in AuditEvent, where: e.plan_version_id == ^draft.id, select: e.event_type)
        )

      assert :saas_plan_version_drafted in events
      assert :saas_plan_version_archived in events
      assert :saas_plan_version_restored in events
    end

    test "the database keeps published content and prices immutable" do
      published = published_plan!()

      assert_raise Postgrex.Error, ~r/immutable|published/, fn ->
        Repo.query!("UPDATE saas_plan_versions SET name = 'x' WHERE id = $1", [
          Ecto.UUID.dump!(published.id)
        ])
      end

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE saas_price_versions SET amount_minor = 1 WHERE id = $1", [
          Ecto.UUID.dump!(price(published).id)
        ])
      end

      assert_raise Postgrex.Error, fn ->
        Repo.query!("DELETE FROM saas_plan_versions WHERE id = $1", [
          Ecto.UUID.dump!(published.id)
        ])
      end

      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "INSERT INTO saas_price_versions (id, plan_version_id, interval, currency, pricing, amount_minor) " <>
            "VALUES (gen_random_uuid(), $1, 'month', 'EUR', 'fixed', 100)",
          [Ecto.UUID.dump!(published.id)]
        )
      end
    end

    test "retiring removes a version from new subscriptions", ctx do
      published = published_plan!()
      {:ok, retired} = Catalog.retire(published.id, operator())
      assert retired.status == :retired

      assert {:error, {:conflict, %{saas_plan_version: "retired"}}} =
               request_saas(ctx.owner, ctx.gym.id, published, price(published))
    end
  end

  describe "gym subscription" do
    test "an intent is pending, grants nothing, replays and refuses a reused key", ctx do
      plan = published_plan!()
      key = Ecto.UUID.generate()

      assert {:ok, {pending, :created}} =
               request_saas(ctx.owner, ctx.gym.id, plan, price(plan), key)

      assert pending.status == :pending_activation
      assert pending.activation_evidence_id == nil
      assert pending.current_period_start == nil

      assert {:ok, {same, :existing}} =
               request_saas(ctx.owner, ctx.gym.id, plan, price(plan), key)

      assert same.id == pending.id

      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               request_saas(ctx.owner, ctx.gym.id, plan, price(plan, :year), key)

      assert {:error, {:conflict, %{saas_subscription: "current_exists"}}} =
               request_saas(ctx.owner, ctx.gym.id, plan, price(plan, :year))

      assert Entitlements.gym_feature(ctx.gym.id, "gym.member_management") ==
               {:denied, :pending_activation}

      assert events(ctx.gym.id, "saas_") == [:saas_subscription_requested]
    end

    test "a client can neither activate nor pay: status, receipt and payment fields are refused",
         ctx do
      plan = published_plan!()

      for extra <- [
            %{"status" => "active"},
            %{"receipt" => "fake-receipt"},
            %{"payment" => %{"card" => "4242"}},
            %{"activation_evidence_id" => Ecto.UUID.generate()}
          ] do
        attrs =
          Map.merge(
            %{
              "plan_version_id" => plan.id,
              "price_version_id" => price(plan).id,
              "client_request_id" => Ecto.UUID.generate()
            },
            extra
          )

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Billing.request_gym_subscription(
                   ctx.owner,
                   live_session!(ctx.owner),
                   ctx.gym.id,
                   attrs
                 )

        [field] = Map.keys(extra)
        assert Enum.any?(changeset.errors, fn {key, _} -> to_string(key) == field end)
      end

      assert Repo.aggregate(from(s in GymSubscription, where: s.gym_id == ^ctx.gym.id), :count) ==
               0
    end

    test "quote-only, unpublished and foreign prices are refused", ctx do
      quote =
        published_plan!(%{
          "prices" => [
            %{"interval" => "month", "currency" => "PLN", "pricing" => "quote_required"}
          ]
        })

      assert {:error, {:conflict, %{saas_price_version: "quote_required"}}} =
               request_saas(ctx.owner, ctx.gym.id, quote, hd(quote.prices))

      draft = draft_plan!()

      assert {:error, {:conflict, %{saas_plan_version: "draft"}}} =
               request_saas(ctx.owner, ctx.gym.id, draft, price(draft))

      other = published_plan!()

      assert {:error, {:conflict, %{saas_price_version: "not_found"}}} =
               request_saas(ctx.owner, ctx.gym.id, draft, price(other))
    end

    test "only the owner acts on billing; other staff are forbidden, strangers see 404", ctx do
      plan = published_plan!()
      manager = registered!("bill-mgr")
      staff!(ctx.gym.id, manager, :manager)
      stranger = registered!("bill-x")

      assert {:error, :forbidden} = request_saas(manager, ctx.gym.id, plan, price(plan))
      assert {:error, :forbidden} = Billing.list_gym_subscriptions(manager, ctx.gym.id)
      assert {:error, :not_found} = request_saas(stranger, ctx.gym.id, plan, price(plan))
      assert {:error, :not_found} = Billing.list_gym_subscriptions(stranger, ctx.gym.id)
      assert {:ok, _} = Entitlements.gym_projection(manager, ctx.gym.id)
      assert {:error, :not_found} = Entitlements.gym_projection(stranger, ctx.gym.id)
    end

    test "a draft gym cannot subscribe", %{owner: owner} do
      draft = draft_gym!(owner)
      plan = published_plan!()

      assert {:error, {:conflict, %{setup_status: "draft"}}} =
               request_saas(owner, draft.id, plan, price(plan))
    end

    test "activation needs a trusted provider; evidence is never replayed", ctx do
      plan = published_plan!()
      subscription = pending_saas!(ctx.owner, ctx.gym.id, plan)

      assert Activation.trusted_providers() == [SimpleFit.BillingTestProvider]

      assert {:error, :untrusted_provider} =
               Subscriptions.activate(subscription.id, __MODULE__, evidence(@now, @period_end))

      assert {:error, :unavailable} =
               Subscriptions.activate(subscription.id, SimpleFit.BillingTestProvider, :fail)

      assert {:error, :invalid_evidence} =
               Subscriptions.activate(
                 subscription.id,
                 SimpleFit.BillingTestProvider,
                 evidence(@period_end, @now)
               )

      assert Repo.get!(GymSubscription, subscription.id).status == :pending_activation

      assert {:ok, active} = activate_saas(subscription.id, @now, @period_end, @now, "ref-1")
      assert active.status == :active
      assert active.current_period_end == @period_end

      other_gym = completed_gym!(ctx.owner)
      other = pending_saas!(ctx.owner, other_gym.id, plan)

      assert {:error, :evidence_replayed} =
               activate_saas(other.id, @now, @period_end, @now, "ref-1")

      assert {:error, {:conflict, %{saas_subscription: "active"}}} =
               activate_saas(subscription.id, @now, @period_end)

      assert events(ctx.gym.id, "saas_") ==
               Enum.sort([:saas_subscription_requested, :saas_subscription_activated])
    end

    test "the database refuses an active subscription without evidence and illegal transitions",
         ctx do
      plan = published_plan!()
      subscription = pending_saas!(ctx.owner, ctx.gym.id, plan)
      id = Ecto.UUID.dump!(subscription.id)

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE gym_saas_subscriptions SET status = 'active' WHERE id = $1", [id])
      end

      {:ok, _} = activate_saas(subscription.id, @now, @period_end)

      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE gym_saas_subscriptions SET status = 'pending_activation', activation_evidence_id = NULL, " <>
            "activated_at = NULL, current_period_start = NULL, current_period_end = NULL WHERE id = $1",
          [id]
        )
      end

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE gym_saas_subscriptions SET price_version_id = $2 WHERE id = $1", [
          id,
          Ecto.UUID.dump!(price(plan, :year).id)
        ])
      end
    end

    test "cancellation: immediate, at period end, idempotent, and final", ctx do
      plan = published_plan!()

      pending = pending_saas!(ctx.owner, ctx.gym.id, plan)

      assert {:ok, %{status: :cancelled, cancel_mode: :immediate}} =
               Billing.cancel_gym_subscription(
                 ctx.owner,
                 live_session!(ctx.owner),
                 ctx.gym.id,
                 pending.id,
                 %{"mode" => "period_end"}
               )

      active = active_saas!(ctx.owner, ctx.gym.id, plan, @now, @period_end)

      cancel =
        &Billing.cancel_gym_subscription(
          ctx.owner,
          live_session!(ctx.owner),
          ctx.gym.id,
          active.id,
          &1
        )

      assert {:ok, scheduled} = cancel.(%{"mode" => "period_end"})
      assert scheduled.status == :cancellation_scheduled
      assert scheduled.cancellation_effective_at == @period_end
      assert {:ok, %{status: :cancellation_scheduled}} = cancel.(%{"mode" => "period_end"})

      assert {:entitled, _} = Entitlements.gym_feature(ctx.gym.id, "gym.member_management")

      assert {:error, %Ecto.Changeset{}} = cancel.(%{"mode" => "later"})
      assert {:error, %Ecto.Changeset{}} = cancel.(%{"mode" => "immediate", "refund" => true})

      assert {:ok, cancelled} = cancel.(%{"mode" => "immediate"})
      assert cancelled.status == :cancelled
      assert {:ok, %{status: :cancelled}} = cancel.(%{"mode" => "immediate"})

      assert Entitlements.gym_feature(ctx.gym.id, "gym.member_management") ==
               {:denied, :not_in_force}

      assert events(ctx.gym.id, "saas_subscription_cancel") ==
               Enum.sort([
                 :saas_subscription_cancelled,
                 :saas_subscription_cancellation_scheduled,
                 :saas_subscription_cancelled
               ])

      assert {:error, :not_found} =
               Billing.cancel_gym_subscription(
                 ctx.owner,
                 live_session!(ctx.owner),
                 completed_gym!(ctx.owner).id,
                 active.id,
                 %{"mode" => "immediate"}
               )
    end

    test "period end: active expires (no renewal), a scheduled cancellation takes effect", ctx do
      plan = published_plan!()
      active = active_saas!(ctx.owner, ctx.gym.id, plan, @now, @period_end)

      other_gym = completed_gym!(ctx.owner)
      scheduled = active_saas!(ctx.owner, other_gym.id, plan, @now, @period_end)

      {:ok, _} =
        Billing.cancel_gym_subscription(
          ctx.owner,
          live_session!(ctx.owner),
          other_gym.id,
          scheduled.id,
          %{"mode" => "period_end"}
        )

      assert {:ok, 0} = Subscriptions.advance(DateTime.add(@period_end, -1))

      assert Entitlements.gym_feature(ctx.gym.id, "gym.member_management", @period_end) ==
               {:denied, :not_in_force}

      assert {:ok, 2} = Subscriptions.advance(@period_end)
      assert Repo.get!(GymSubscription, active.id).status == :expired
      assert Repo.get!(GymSubscription, scheduled.id).status == :cancelled
      assert {:ok, 0} = Subscriptions.advance(@period_end)

      assert {:error, {:conflict, %{saas_subscription: "expired"}}} =
               Billing.cancel_gym_subscription(
                 ctx.owner,
                 live_session!(ctx.owner),
                 ctx.gym.id,
                 active.id,
                 %{"mode" => "immediate"}
               )

      # A new intent is possible once nothing is current.
      assert {:ok, {_, :created}} = request_saas(ctx.owner, ctx.gym.id, plan, price(plan))
    end

    test "an ownership transfer moves billing authority without touching the subscription", ctx do
      plan = published_plan!()
      subscription = pending_saas!(ctx.owner, ctx.gym.id, plan)
      heir = registered!("bill-heir")
      membership = staff!(ctx.gym.id, heir, :manager)

      {:ok, _} = Gyms.transfer_ownership(ctx.owner, ctx.gym.id, membership.id, :leave)

      assert {:ok, [%{id: id, status: :pending_activation}]} =
               Billing.list_gym_subscriptions(heir, ctx.gym.id)

      assert id == subscription.id
      # The previous owner left the gym: no staff membership, so no existence.
      assert {:error, :not_found} = Billing.list_gym_subscriptions(ctx.owner, ctx.gym.id)
    end
  end

  describe "boundaries" do
    test "no invoice, refund, payment or credit record exists, and no coaching data is created",
         ctx do
      relationships = Repo.aggregate("coach_fighter_relationships", :count)
      fighters = Repo.aggregate("fighter_profiles", :count)
      plan = published_plan!()
      active = active_saas!(ctx.owner, ctx.gym.id, plan, @now, @period_end)

      {:ok, _} =
        Billing.cancel_gym_subscription(
          ctx.owner,
          live_session!(ctx.owner),
          ctx.gym.id,
          active.id,
          %{"mode" => "immediate"}
        )

      %{rows: tables} =
        Repo.query!(
          "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND " <>
            "tablename ~ '(invoice|refund|payment|payout|credit|ledger|receipt)'"
        )

      assert tables == []
      assert Repo.aggregate("coach_fighter_relationships", :count) == relationships
      assert Repo.aggregate("fighter_profiles", :count) == fighters
    end

    test "a gym with subscriptions is never deleted by accident; the catalog it references is kept",
         ctx do
      plan = published_plan!()
      pending_saas!(ctx.owner, ctx.gym.id, plan)

      assert_raise Postgrex.Error, fn ->
        Repo.query!("DELETE FROM gyms WHERE id = $1", [Ecto.UUID.dump!(ctx.gym.id)])
      end

      assert_raise Postgrex.Error, fn ->
        Repo.query!("DELETE FROM saas_plan_versions WHERE id = $1", [Ecto.UUID.dump!(plan.id)])
      end

      # The maintenance purge removes the gym with its subscriptions.
      :ok = purge_gyms!([ctx.gym.id])

      assert Repo.aggregate(from(s in GymSubscription, where: s.gym_id == ^ctx.gym.id), :count) ==
               0

      assert {:ok, _} = Catalog.get_version(plan.id)
    end
  end

  describe "entitlements" do
    test "fail closed: unknown key, no subscription, not in plan; entitled only in force", ctx do
      assert Entitlements.gym_feature(ctx.gym.id, "gym.unknown") == {:denied, :unknown_feature}

      assert Entitlements.gym_feature(ctx.gym.id, "gym.member_management") ==
               {:denied, :no_subscription}

      plan =
        published_plan!(%{
          "entitlements" => [
            %{"feature_key" => "gym.additional_locations", "quantity_limit" => 3}
          ]
        })

      active = active_saas!(ctx.owner, ctx.gym.id, plan, @now, @period_end)

      assert Entitlements.gym_feature(ctx.gym.id, "gym.additional_locations") ==
               {:entitled, %{subscription_id: active.id, quantity_limit: 3}}

      assert Entitlements.gym_feature(ctx.gym.id, "gym.custom_branding") ==
               {:denied, :not_in_plan}

      assert Entitlements.gym_feature(
               ctx.gym.id,
               "gym.additional_locations",
               DateTime.add(@now, -1)
             ) ==
               {:denied, :not_in_force}

      {:ok, projection} = Entitlements.gym_projection(ctx.owner, ctx.gym.id)

      assert projection.subscription == %{
               subscription_id: active.id,
               status: :active,
               in_force: true
             }

      assert length(projection.features) == length(Features.keys())
      assert Enum.all?(projection.features, &(&1.enforced == false))

      assert %{status: :entitled, quantity_limit: 3, reason: nil} =
               Enum.find(projection.features, &(&1.key == "gym.additional_locations"))

      assert %{status: :denied, reason: :not_in_plan} =
               Enum.find(projection.features, &(&1.key == "gym.timetable"))
    end

    test "no gym feature is gated: a gym without any subscription keeps working", ctx do
      assert Entitlements.gym_feature(ctx.gym.id, "gym.timetable") == {:denied, :no_subscription}
      assert {:ok, _} = Gyms.list_staff(ctx.owner, ctx.gym.id, %{})
      venue = SimpleFit.TimetableHelpers.venue!(ctx.owner, ctx.gym.id)
      assert venue.venue_id

      assert Entitlements.class_admission(Ecto.UUID.generate(), Ecto.UUID.generate()) ==
               :not_required
    end

    test "telemetry carries the key and outcome only", ctx do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:simple_fit, :entitlements, :evaluated]])

      Entitlements.gym_feature(ctx.gym.id, "gym.timetable")
      Entitlements.gym_feature(ctx.gym.id, "secret@example.com")

      assert_receive {[:simple_fit, :entitlements, :evaluated], ^ref, %{count: 1},
                      %{feature: "gym.timetable", outcome: :denied} = meta}

      assert map_size(meta) == 2

      assert_receive {[:simple_fit, :entitlements, :evaluated], ^ref, _,
                      %{feature: "unknown", outcome: :denied}}

      :telemetry.detach(ref)
    end
  end
end
