defmodule SimpleFit.BillingRaceTest do
  @moduledoc """
  SF-101 commerce under true concurrency and real commits, on separate
  connections outside the SQL sandbox: the gym row lock, the plan and
  product row locks, the partial unique indexes (one current subscription,
  one draft, one published version), the idempotency indexes, the evidence
  reference index and the subscription row lock are exercised for real.
  Every test checks the committed state (rows, counts, audit events).
  Committed rows are removed afterwards through the purge switch.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Billing, Clock, Entitlements, Gyms, Repo}
  alias SimpleFit.Billing.{Catalog, GymSubscription, PlanVersion}
  alias SimpleFit.Gyms.{AuditEvent, Gym, MemberPriceVersion, MemberProductSubscription}
  alias SimpleFit.Gyms.StaffMembership

  @now ~U[2026-01-05 12:00:00.000000Z]
  @period_end ~U[2026-02-05 12:00:00.000000Z]

  setup do
    Sandbox.mode(Repo, :auto)
    Clock.freeze(@now)
    reset_limits()
    {:ok, users} = Agent.start(fn -> [] end)
    {:ok, keys} = Agent.start(fn -> [] end)
    first_job = Repo.one(from(j in Oban.Job, select: max(j.id))) || 0
    started = DateTime.utc_now()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(j in Oban.Job, where: j.id > ^first_job))
      ids = Agent.get(users, & &1)

      gym_ids =
        Repo.all(
          from(g in Gym,
            left_join: m in StaffMembership,
            on: m.gym_id == g.id,
            where: g.created_by_user_id in ^ids or m.user_id in ^ids,
            distinct: true,
            select: g.id
          )
        )

      references =
        Repo.all(
          from(e in SimpleFit.Billing.ActivationEvidence,
            where: e.inserted_at >= ^started,
            select: e.provider_reference
          )
        )

      purge_gyms!(gym_ids)
      purge_billing!(Agent.get(keys, & &1), references)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      reset_limits()
      Agent.stop(users)
      Agent.stop(keys)
      Clock.unfreeze()
      Sandbox.mode(Repo, :manual)
    end)

    owner = track(users, registered_as!(registered!("bilrace-owner"), "Yauheni Bykovski"))
    gym = completed_gym!(owner)
    %{users: users, keys: keys, owner: owner, gym: gym}
  end

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp plan!(ctx, overrides \\ %{}) do
    key = plan_key("race")
    Agent.update(ctx.keys, &[key | &1])
    published_plan!(overrides, key)
  end

  # A gym of its own owner (gym creation is rate-limited per user).
  defp new_gym!(ctx) do
    owner = track(ctx.users, registered_as!(registered!("bilrace-o"), "Ola Nowak"))
    {owner, completed_gym!(owner)}
  end

  defp reset_limits do
    Repo.delete_all("auth_rate_limits")
    Repo.delete_all("rate_limit_events")
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(60_000)

  defp events(gym_id, type),
    do:
      Repo.aggregate(
        from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type),
        :count
      )

  defp subscriptions(gym_id),
    do: Repo.all(from(s in GymSubscription, where: s.gym_id == ^gym_id))

  defp created(results), do: Enum.count(results, &match?({:ok, {_, :created}}, &1))

  test "20 intents with different keys: one current subscription, 19 conflicts", ctx do
    plan = plan!(ctx)

    results =
      concurrently(
        for _ <- 1..20, do: fn -> request_saas(ctx.owner, ctx.gym.id, plan, price(plan)) end
      )

    assert created(results) == 1

    assert Enum.count(
             results,
             &(&1 == {:error, {:conflict, %{saas_subscription: "current_exists"}}})
           ) ==
             19

    assert [%{status: :pending_activation}] = subscriptions(ctx.gym.id)
    assert events(ctx.gym.id, :saas_subscription_requested) == 1
  end

  test "the same intent 20 times is one subscription", ctx do
    plan = plan!(ctx)
    key = Ecto.UUID.generate()

    results =
      concurrently(
        for _ <- 1..20, do: fn -> request_saas(ctx.owner, ctx.gym.id, plan, price(plan), key) end
      )

    assert created(results) == 1
    assert Enum.count(results, &match?({:ok, {_, :existing}}, &1)) == 19
    assert length(subscriptions(ctx.gym.id)) == 1
    assert events(ctx.gym.id, :saas_subscription_requested) == 1
  end

  test "concurrent publication of one draft and concurrent drafts of one plan: one each", ctx do
    key = plan_key("race")
    Agent.update(ctx.keys, &[key | &1])
    draft = draft_plan!(%{}, key)

    published =
      concurrently(
        for _ <- 1..10, do: fn -> Catalog.publish(draft.id, "SF-101-RACE", operator()) end
      )

    assert Enum.count(published, &match?({:ok, %PlanVersion{status: :published}}, &1)) == 1

    assert Enum.count(
             published,
             &(&1 == {:error, {:conflict, %{saas_plan_version: "published"}}})
           ) ==
             9

    drafts =
      concurrently(for _ <- 1..10, do: fn -> Catalog.draft(key, plan_attrs(), operator()) end)

    assert Enum.count(drafts, &match?({:ok, %PlanVersion{}}, &1)) == 1

    assert Enum.count(drafts, &(&1 == {:error, {:conflict, %{saas_plan: "draft_exists"}}})) == 9

    statuses =
      Repo.all(
        from(v in PlanVersion, join: p in assoc(v, :plan), where: p.key == ^key, select: v.status)
      )

    assert Enum.sort(statuses) == [:draft, :published]
  end

  test "publishing a new version while gyms subscribe: every intent names a published version",
       ctx do
    key = plan_key("race")
    Agent.update(ctx.keys, &[key | &1])
    v1 = published_plan!(%{}, key)
    v2 = draft_plan!(%{"name" => "Starter 2"}, key)

    gyms = for _ <- 1..10, do: new_gym!(ctx)

    results =
      concurrently(
        [fn -> Catalog.publish(v2.id, "SF-101-RACE", operator()) end] ++
          for({owner, g} <- gyms, do: fn -> request_saas(owner, g.id, v1, price(v1)) end)
      )

    [publication | intents] = results
    assert {:ok, %PlanVersion{status: :published}} = publication

    for result <- intents do
      assert match?({:ok, {_, :created}}, result) or
               result == {:error, {:conflict, %{saas_plan_version: "superseded"}}}
    end

    # Every committed intent references v1, created while it was published.
    for {_, g} <- gyms, s <- subscriptions(g.id), do: assert(s.plan_version_id == v1.id)
    {:ok, old} = Catalog.get_version(v1.id)
    assert old.status == :superseded
  end

  test "concurrent cancellations (immediate and period end) settle on one outcome", ctx do
    plan = plan!(ctx)

    for _round <- 1..5 do
      reset_limits()
      {owner, gym} = new_gym!(ctx)
      active = active_saas!(owner, gym.id, plan, @now, @period_end)

      results =
        concurrently(
          for mode <- List.duplicate("immediate", 5) ++ List.duplicate("period_end", 5) do
            fn ->
              Billing.cancel_gym_subscription(
                owner,
                live_session!(owner),
                gym.id,
                active.id,
                %{"mode" => mode}
              )
            end
          end
        )

      assert Enum.all?(results, &match?({:ok, %GymSubscription{}}, &1))
      final = Repo.get!(GymSubscription, active.id)
      assert final.status == :cancelled
      assert events(gym.id, :saas_subscription_cancelled) == 1
      assert events(gym.id, :saas_subscription_cancellation_scheduled) in [0, 1]
    end
  end

  test "the same evidence reference activates exactly one subscription", ctx do
    plan = plan!(ctx)

    pending =
      for _ <- 1..10 do
        {owner, gym} = new_gym!(ctx)
        pending_saas!(owner, gym.id, plan)
      end

    results =
      concurrently(
        for s <- pending,
            do: fn -> activate_saas(s.id, @now, @period_end, @now, "race_shared_ref") end
      )

    assert Enum.count(results, &match?({:ok, %GymSubscription{status: :active}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :evidence_replayed})) == 9

    assert Repo.aggregate(
             from(s in GymSubscription,
               where: s.id in ^Enum.map(pending, & &1.id) and s.status == :active
             ),
             :count
           ) == 1
  end

  test "replayed activation attempts without trusted evidence activate nothing", ctx do
    plan = plan!(ctx)
    pending = pending_saas!(ctx.owner, ctx.gym.id, plan)
    payload = evidence(@now, @period_end, "race_untrusted")

    results =
      concurrently(
        for _ <- 1..20,
            do: fn -> Billing.Subscriptions.activate(pending.id, __MODULE__, payload, @now) end
      )

    assert Enum.all?(results, &(&1 == {:error, :untrusted_provider}))
    assert Repo.get!(GymSubscription, pending.id).status == :pending_activation

    assert Repo.aggregate(
             from(e in SimpleFit.Billing.ActivationEvidence,
               where: e.provider_reference == "race_untrusted"
             ),
             :count
           ) == 0

    assert events(ctx.gym.id, :saas_subscription_activated) == 0

    assert Entitlements.gym_feature(ctx.gym.id, "gym.member_management") ==
             {:denied, :pending_activation}
  end

  test "activating one subscription concurrently is one activation and one period", ctx do
    plan = plan!(ctx)
    pending = pending_saas!(ctx.owner, ctx.gym.id, plan)

    results =
      concurrently(
        for i <- 1..10,
            do: fn -> activate_saas(pending.id, @now, @period_end, @now, "race_#{i}") end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, &(&1 == {:error, {:conflict, %{saas_subscription: "active"}}})) ==
             9

    assert Repo.aggregate(
             from(p in SimpleFit.Billing.SubscriptionPeriod,
               where: p.subscription_id == ^pending.id
             ),
             :count
           ) == 1

    assert events(ctx.gym.id, :saas_subscription_activated) == 1
  end

  test "entitlement reads racing an immediate cancellation never see a half state", ctx do
    plan = plan!(ctx)
    active = active_saas!(ctx.owner, ctx.gym.id, plan, @now, @period_end)

    results =
      concurrently(
        [
          fn ->
            Billing.cancel_gym_subscription(
              ctx.owner,
              live_session!(ctx.owner),
              ctx.gym.id,
              active.id,
              %{"mode" => "immediate"}
            )
          end
        ] ++
          for(
            _ <- 1..20,
            do: fn -> Entitlements.gym_feature(ctx.gym.id, "gym.member_management") end
          )
      )

    [cancel | reads] = results
    assert {:ok, %GymSubscription{status: :cancelled}} = cancel

    for read <- reads do
      assert read == {:entitled, %{subscription_id: active.id, quantity_limit: nil}} or
               read == {:denied, :not_in_force}
    end

    assert Entitlements.gym_feature(ctx.gym.id, "gym.member_management") ==
             {:denied, :not_in_force}
  end

  test "an ownership transfer racing the owner's intent: authority is decided by commit order",
       ctx do
    plan = plan!(ctx)

    for _round <- 1..5 do
      {owner, gym} = new_gym!(ctx)
      heir = track(ctx.users, registered!("bilrace-heir"))
      membership = staff!(gym.id, heir, :manager)

      [transfer, intent] =
        concurrently([
          fn -> Gyms.transfer_ownership(owner, gym.id, membership.id, :leave) end,
          fn -> request_saas(owner, gym.id, plan, price(plan)) end
        ])

      assert {:ok, _} = transfer

      case intent do
        {:ok, {subscription, :created}} ->
          # Committed before the transfer: the gym keeps it under the new owner.
          assert {:ok, [%{id: id}]} = Billing.list_gym_subscriptions(heir, gym.id)
          assert id == subscription.id

        {:error, reason} ->
          assert reason in [:not_found, :forbidden]
          assert subscriptions(gym.id) == []
      end
    end
  end

  test "20 staff prices on one version get distinct sequences; the latest is current", ctx do
    product = published_product!(ctx.owner, ctx.gym.id)

    results =
      concurrently(
        for i <- 1..20 do
          fn ->
            Gyms.add_member_product_price(
              ctx.owner,
              live_session!(ctx.owner),
              ctx.gym.id,
              product.product_id,
              product.published.version_id,
              %{
                "client_request_id" => Ecto.UUID.generate(),
                "currency" => "PLN",
                "amount" => "#{100 + i}"
              }
            )
          end
        end
      )

    assert created(results) == 20

    sequences =
      Repo.all(
        from(p in MemberPriceVersion,
          where: p.product_version_id == ^product.published.version_id and p.currency == "PLN",
          select: p.sequence,
          order_by: p.sequence
        )
      )

    assert sequences == Enum.to_list(1..21)
    assert events(ctx.gym.id, :member_product_price_created) == 20
  end

  test "member intents racing a product retirement never subscribe to a retired product", ctx do
    product = published_product!(ctx.owner, ctx.gym.id)
    code = join_code!(ctx.owner, ctx.gym.id)

    racers =
      for i <- 1..10 do
        {user, member} = active_member!(ctx.owner, ctx.gym.id, code, "Racer #{i} Member")
        track(ctx.users, user)
        {user, member.gym_member_id}
      end

    [retire | intents] =
      concurrently(
        [
          fn ->
            Gyms.retire_member_product(
              ctx.owner,
              live_session!(ctx.owner),
              ctx.gym.id,
              product.product_id
            )
          end
        ] ++
          for(
            {user, member_id} <- racers,
            do: fn -> request_product(user, member_id, product) end
          )
      )

    assert {:ok, %{status: :retired}} = retire

    for result <- intents do
      assert match?({:ok, {_, :created}}, result) or
               match?({:error, {:conflict, %{member_product: "retired"}}}, result) or
               match?({:error, {:conflict, %{member_product_version: "retired"}}}, result)
    end

    committed =
      Repo.aggregate(from(s in MemberProductSubscription, where: s.gym_id == ^ctx.gym.id), :count)

    assert committed == created(intents)
    assert events(ctx.gym.id, :member_product_subscription_requested) == committed
  end

  test "a member intent racing leaving the gym ends cancelled or refused, never pending", ctx do
    product = published_product!(ctx.owner, ctx.gym.id)
    code = join_code!(ctx.owner, ctx.gym.id)

    for i <- 1..5 do
      {user, member} = active_member!(ctx.owner, ctx.gym.id, code, "Leaver #{i} Member")
      track(ctx.users, user)

      [_leave, intent] =
        concurrently([
          fn -> Gyms.leave_gym_membership(user, live_session!(user), member.gym_member_id) end,
          fn -> request_product(user, member.gym_member_id, product) end
        ])

      rows =
        Repo.all(
          from(s in MemberProductSubscription, where: s.gym_member_id == ^member.gym_member_id)
        )

      case intent do
        {:ok, {_, :created}} ->
          assert [%{status: :cancelled, cancel_reason: :membership_ended}] = rows

        {:error, _} ->
          assert rows == []
      end
    end
  end
end
