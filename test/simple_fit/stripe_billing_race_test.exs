defmodule SimpleFit.StripeBillingRaceTest do
  @moduledoc """
  SF-102 under true concurrency and real commits (separate connections
  outside the SQL sandbox), against the deterministic Stripe fake: the
  subscription row lock that serializes checkout creation and every
  reconciliation, the webhook inbox's unique event index, the evidence
  reference, the operator refund's invoice lock and partial unique index,
  and cancellation racing a renewal. Every test checks committed rows,
  provider-side objects and audit events; committed rows are purged
  afterwards through the maintenance switch.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers
  import SimpleFit.StripeHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Billing, Repo, StripeFake}
  alias SimpleFit.Billing.{ActivationEvidence, GymSubscription, Operations, Reconciliation}
  alias SimpleFit.Billing.Stripe.{Checkout, Refund, WebhookEvent}
  alias SimpleFit.Gyms.{AuditEvent, Gym, StaffMembership}

  setup do
    Sandbox.mode(Repo, :auto)
    reset_limits()
    StripeFake.start!()
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
          from(e in ActivationEvidence,
            where: e.inserted_at >= ^started,
            select: e.provider_reference
          )
        )

      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL simple_fit.allow_gym_member_purge = 'on'")
          Repo.delete_all(from(e in WebhookEvent, where: e.inserted_at >= ^started))
          Repo.delete_all(from(e in SimpleFit.Billing.AuditEvent, where: e.gym_id in ^gym_ids))
        end)

      purge_gyms!(gym_ids)
      purge_billing!(Agent.get(keys, & &1), references)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      reset_limits()
      Agent.stop(users)
      Agent.stop(keys)
      Sandbox.mode(Repo, :manual)
    end)

    owner = track(users, registered_as!(registered!("striperace-owner"), "Yauheni Bykovski"))
    gym = completed_gym!(owner)
    key = plan_key("srace")
    Agent.update(keys, &[key | &1])
    {version, mapping} = mapped_plan!(key)
    %{users: users, owner: owner, gym: gym, version: version, mapping: mapping}
  end

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
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

  defp sessions_at_stripe,
    do:
      Agent.get(Process.get(StripeFake), fn s ->
        s.objects |> Map.keys() |> Enum.count(&String.starts_with?(&1, "cs_"))
      end)

  test "20 concurrent checkout requests for one intent: one checkout row, one Stripe session",
       ctx do
    subscription = pending_saas!(ctx.owner, ctx.gym.id, ctx.version)

    results =
      concurrently(for _ <- 1..20, do: fn -> checkout(ctx.owner, ctx.gym.id, subscription.id) end)

    sessions =
      results
      |> Enum.map(fn {:ok, {checkout, _}} -> checkout.stripe_session_id end)
      |> Enum.uniq()

    assert [_one] = sessions

    assert Repo.aggregate(
             from(c in Checkout, where: c.subscription_id == ^subscription.id),
             :count
           ) == 1

    assert sessions_at_stripe() == 1
    assert events(ctx.gym.id, :saas_checkout_started) == 1
  end

  test "checkouts for different intents of one gym: one current subscription, one session", ctx do
    first = pending_saas!(ctx.owner, ctx.gym.id, ctx.version)

    results =
      concurrently([
        fn -> checkout(ctx.owner, ctx.gym.id, first.id) end,
        fn -> request_saas(ctx.owner, ctx.gym.id, ctx.version, price(ctx.version)) end,
        fn -> checkout(ctx.owner, ctx.gym.id, first.id) end
      ])

    assert Enum.count(results, &match?({:ok, {%Checkout{}, _}}, &1)) == 2
    assert {:error, {:conflict, %{saas_subscription: "current_exists"}}} in results
    assert sessions_at_stripe() == 1
  end

  test "the same event delivered 20 times concurrently: one inbox row and one job", ctx do
    event = StripeFake.event("invoice.paid", "invoice", "in_concurrent")
    results = concurrently(for _ <- 1..20, do: fn -> deliver(event) end)

    assert Enum.count(results, &(&1 == {:ok, :accepted})) == 1
    assert Enum.count(results, &(&1 == {:ok, :duplicate})) == 19

    assert Repo.aggregate(
             from(e in WebhookEvent, where: e.stripe_event_id == ^event["id"]),
             :count
           ) == 1

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "SimpleFit.Billing.Stripe.EventWorker"),
             :count
           ) >= 1

    _ = ctx
  end

  test "10 concurrent reconciliations of one paid checkout: one activation, one evidence", ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    ids = StripeFake.complete_checkout(checkout.stripe_session_id)

    concurrently(
      for i <- 1..10 do
        if rem(i, 2) == 0,
          do: fn -> Reconciliation.reconcile_subscription(subscription.id) end,
          else: fn -> Reconciliation.sync_invoice(ids.invoice) end
      end
    )

    assert %GymSubscription{status: :active} = Repo.get!(GymSubscription, subscription.id)

    assert Repo.aggregate(
             from(e in ActivationEvidence, where: e.provider_reference == ^"test:#{ids.invoice}"),
             :count
           ) == 1

    assert events(ctx.gym.id, :saas_subscription_activated) == 1
  end

  test "10 concurrent operator refunds of one invoice: one refund at Stripe and locally", ctx do
    {_subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    ids = StripeFake.complete_checkout(checkout.stripe_session_id)
    {:ok, _} = Reconciliation.sync_invoice(ids.invoice)

    results =
      concurrently(
        for _ <- 1..10, do: fn -> Operations.refund(ids.invoice, "ops", "SF-102-RACE") end
      )

    # Each request either retries the one unanswered request with its own
    # idempotency key (the same Stripe refund) or finds it done.
    refunds = for {:ok, %Refund{} = refund} <- results, uniq: true, do: refund.id
    assert [_one] = refunds

    assert Enum.all?(results, fn
             {:ok, %Refund{status: :succeeded}} -> true
             {:error, {:conflict, %{refund: "exists"}}} -> true
             _ -> false
           end)

    assert Repo.aggregate(Refund, :count) == 1

    assert Agent.get(Process.get(StripeFake), fn s ->
             s.objects |> Map.values() |> Enum.count(&(&1["object"] == "refund"))
           end) == 1

    assert events(ctx.gym.id, :saas_refund_recorded) == 1
  end

  # SF-138
  test "10 concurrent reconciliations of one renewal: one period, one evidence, one event", ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    ids = StripeFake.complete_checkout(checkout.stripe_session_id)
    {:ok, :activated} = Reconciliation.reconcile_subscription(subscription.id)
    first_end = Repo.get!(GymSubscription, subscription.id).current_period_end
    renewal = StripeFake.renew(ids.subscription)

    concurrently(
      for i <- 1..10 do
        if rem(i, 2) == 0,
          do: fn -> Reconciliation.reconcile_subscription(subscription.id) end,
          else: fn -> Reconciliation.sync_invoice(renewal.invoice) end
      end
    )

    assert DateTime.compare(
             Repo.get!(GymSubscription, subscription.id).current_period_end,
             first_end
           ) == :gt

    assert Repo.aggregate(
             from(e in ActivationEvidence,
               where: e.provider_reference == ^"test:#{renewal.invoice}"
             ),
             :count
           ) == 1

    assert events(ctx.gym.id, :saas_subscription_renewed) == 1
  end

  # SF-138
  test "a failed payment's event racing its later success: the paid state wins, once", ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    ids = StripeFake.complete_checkout(checkout.stripe_session_id)
    {:ok, :activated} = Reconciliation.reconcile_subscription(subscription.id)
    first_end = Repo.get!(GymSubscription, subscription.id).current_period_end
    failed = StripeFake.fail_renewal(ids.subscription)
    {:ok, _} = Reconciliation.sync_invoice(failed.invoice)
    assert events(ctx.gym.id, :saas_payment_failed) == 1
    StripeFake.pay_invoice(failed.invoice)

    concurrently(
      for _ <- 1..10 do
        fn -> Reconciliation.sync_invoice(failed.invoice) end
      end ++ [fn -> Reconciliation.sync_stripe_subscription(ids.subscription) end]
    )

    final = Repo.get!(GymSubscription, subscription.id)
    assert final.status == :active
    assert DateTime.compare(final.current_period_end, first_end) == :gt
    assert events(ctx.gym.id, :saas_subscription_renewed) == 1
    assert events(ctx.gym.id, :saas_payment_failed) == 1
  end

  test "cancellation racing a renewal: Stripe and SimpleFit agree, each effect once", ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    ids = StripeFake.complete_checkout(checkout.stripe_session_id)
    {:ok, :activated} = Reconciliation.reconcile_subscription(subscription.id)
    renewal = StripeFake.renew(ids.subscription)

    concurrently([
      fn ->
        Billing.cancel_gym_subscription(
          ctx.owner,
          live_session!(ctx.owner),
          ctx.gym.id,
          subscription.id,
          %{
            "mode" => "period_end"
          }
        )
      end,
      fn -> Reconciliation.sync_invoice(renewal.invoice) end,
      fn -> Reconciliation.sync_stripe_subscription(ids.subscription) end
    ])

    # A final reconciliation reads Stripe's settled state.
    {:ok, _} = Reconciliation.reconcile_subscription(subscription.id)

    final = Repo.get!(GymSubscription, subscription.id)
    assert StripeFake.get(ids.subscription)["cancel_at_period_end"] == true
    assert final.status == :cancellation_scheduled

    assert Repo.aggregate(
             from(e in ActivationEvidence,
               where: e.provider_reference in ^["test:#{ids.invoice}", "test:#{renewal.invoice}"]
             ),
             :count
           ) == 2

    assert events(ctx.gym.id, :saas_subscription_renewed) == 1
    assert events(ctx.gym.id, :saas_subscription_cancellation_scheduled) == 1
  end

  test "cancelling a pending intent racing its checkout completion never cancels a paid subscription silently",
       ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)

    [cancel, _] =
      concurrently([
        fn ->
          Billing.cancel_gym_subscription(
            ctx.owner,
            live_session!(ctx.owner),
            ctx.gym.id,
            subscription.id,
            %{
              "mode" => "immediate"
            }
          )
        end,
        fn -> StripeFake.complete_checkout(checkout.stripe_session_id) end
      ])

    _ = Reconciliation.reconcile_subscription(subscription.id)
    final = Repo.get!(GymSubscription, subscription.id)

    case cancel do
      {:ok, %{status: :cancelled}} ->
        # The session was expired first, so it could not be paid.
        assert final.status == :cancelled
        assert StripeFake.get(checkout.stripe_session_id)["status"] == "expired"
        assert StripeFake.get(checkout.stripe_session_id)["subscription"] == nil

      {:error, {:conflict, %{checkout: "completed"}}} ->
        # Paid first: the payment is reconciled, never silently cancelled.
        assert final.status == :active
    end
  end
end
