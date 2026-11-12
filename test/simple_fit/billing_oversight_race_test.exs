defmodule SimpleFit.BillingOversightRaceTest do
  @moduledoc """
  SF-127's read projections under true concurrency and real commits (separate
  connections outside the SQL sandbox), against the deterministic Stripe fake: reads
  racing duplicate event processing, reconciliation, a failed payment's recovery and a
  lifecycle transition holding the subscription lock; duplicate payment references;
  and proof that reading writes nothing and calls Stripe never. Committed rows are
  purged afterwards through the maintenance switch.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers
  import SimpleFit.StripeHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Repo, StripeFake}

  alias SimpleFit.Billing.{
    ActivationEvidence,
    GymSubscription,
    Oversight,
    Reconciliation,
    Subscriptions,
    Webhooks
  }

  alias SimpleFit.Billing.Stripe.{Invoice, SubscriptionLink, WebhookEvent}
  alias SimpleFit.Gyms.{Gym, StaffMembership}

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

    owner = track(users, registered_as!(registered!("oversight-race"), "Yauheni Bykovski"))
    gym = completed_gym!(owner)
    key = plan_key("orace")
    Agent.update(keys, &[key | &1])
    {version, _mapping} = mapped_plan!(key)
    %{owner: owner, gym: gym, version: version}
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

  # This test's gym only: other suites may have committed rows of their own.
  defp paid_of(gym_id) do
    Repo.aggregate(
      from(i in Invoice, where: i.gym_id == ^gym_id and i.status == :paid and i.mode == :test),
      :count
    )
  end

  defp read(subscription_id), do: Oversight.subscription(subscription_id, DateTime.utc_now())

  test "the same paid event processed 10 times while 10 reads run: counted once, never twice",
       ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    ids = StripeFake.complete_checkout(checkout.stripe_session_id)
    event = StripeFake.event("invoice.paid", "invoice", ids.invoice)
    {:ok, :accepted} = deliver(event)
    id = Repo.get_by!(WebhookEvent, stripe_event_id: event["id"]).id

    results =
      concurrently(
        for(_ <- 1..10, do: fn -> {:process, Webhooks.process(id)} end) ++
          for(_ <- 1..10, do: fn -> {:read, read(subscription.id)} end)
      )

    for {:read, view} <- results do
      # A read sees the subscription before or after activation, never in between:
      # activation and its paid invoice commit together.
      paid = Enum.count(view.invoices, &(&1.status == :paid))
      assert {view.status, paid} in [{:pending_activation, 0}, {:active, 1}]
    end

    final = read(subscription.id)
    assert final.status == :active
    assert Enum.count(final.invoices, &(&1.status == :paid)) == 1
    assert paid_of(ctx.gym.id) == 1
  end

  test "reconciliations racing overview reads: an active subscription is never read without its evidence",
       ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    StripeFake.complete_checkout(checkout.stripe_session_id)

    results =
      concurrently(
        for(
          _ <- 1..8,
          do: fn -> {:reconcile, Reconciliation.reconcile_subscription(subscription.id)} end
        ) ++
          for(_ <- 1..8, do: fn -> {:read, read(subscription.id)} end)
      )

    for {:read, view} <- results do
      if view.status == :active do
        assert [%{source: :activation}] = view.periods
        assert view.reconciliation.state == :in_sync
      else
        assert view.status == :pending_activation
        assert view.periods == []
      end
    end

    assert %GymSubscription{status: :active} = Repo.get!(GymSubscription, subscription.id)
    assert paid_of(ctx.gym.id) == 1
  end

  test "a failed payment's recovery racing reads: an issue or a paid invoice, never both or a sum",
       ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    ids = StripeFake.complete_checkout(checkout.stripe_session_id)
    {:ok, :activated} = Reconciliation.reconcile_subscription(subscription.id)
    failed = StripeFake.fail_renewal(ids.subscription)
    {:ok, _} = Reconciliation.sync_invoice(failed.invoice)
    assert read(subscription.id).invoices |> hd() |> Map.get(:issue) == :payment_failed
    StripeFake.pay_invoice(failed.invoice)

    results =
      concurrently(
        for(_ <- 1..6, do: fn -> {:sync, Reconciliation.sync_invoice(failed.invoice)} end) ++
          for(_ <- 1..6, do: fn -> {:read, read(subscription.id)} end)
      )

    for {:read, view} <- results do
      latest = hd(view.invoices)
      assert {latest.status, latest.issue} in [{:open, :payment_failed}, {:paid, nil}]
    end

    final = read(subscription.id)
    assert Enum.all?(final.invoices, &(&1.issue == nil))
    assert paid_of(ctx.gym.id) == 2
  end

  test "a transition holding the subscription lock neither blocks nor tears a read", ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    StripeFake.complete_checkout(checkout.stripe_session_id)
    {:ok, :activated} = Reconciliation.reconcile_subscription(subscription.id)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, locked} = Subscriptions.lock_for_provider(subscription.id)
          {:ok, _} = Subscriptions.end_by_provider_locked(locked, :cancelled, DateTime.utc_now())
          send(parent, :locked)

          receive do
            :commit -> :ok
          after
            10_000 -> :timeout
          end
        end)
      end)

    assert_receive :locked, 10_000

    # Uncommitted: the read answers at once with the committed state.
    {micros, during} = :timer.tc(fn -> read(subscription.id) end)
    assert during.status == :active
    assert micros < 2_000_000

    send(holder.pid, :commit)
    assert {:ok, :ok} = Task.await(holder, 15_000)
    assert read(subscription.id).status == :cancelled
  end

  test "a duplicate payment reference is one row; the same id in the other mode stays in its mode",
       ctx do
    now = DateTime.utc_now()
    stripe_id = "in_DUP#{System.unique_integer([:positive])}"

    insert = fn mode ->
      try do
        Repo.insert!(
          %Invoice{
            mode: mode,
            gym_id: ctx.gym.id,
            stripe_invoice_id: stripe_id,
            status: :paid,
            payment_status: :succeeded,
            currency: "PLN",
            amount_due: 5_000,
            amount_paid: 5_000,
            amount_remaining: 0,
            total: 5_000,
            paid_at: now,
            provider_created_at: now,
            synced_at: now
          },
          log: false
        )
      rescue
        Ecto.ConstraintError -> :duplicate
      end
    end

    results = concurrently(for _ <- 1..6, do: fn -> insert.(:test) end)
    assert Enum.count(results, &match?(%Invoice{}, &1)) == 1
    assert Enum.count(results, &(&1 == :duplicate)) == 5
    assert %Invoice{mode: :live} = insert.(:live)

    for mode <- [:test, :live] do
      {rows, nil} = Oversight.invoices_page(%{mode: mode, gym_id: ctx.gym.id}, 50, nil)
      assert [%{amount_paid_minor: 5_000, mode: ^mode}] = rows
    end
  end

  test "reading writes nothing and never calls Stripe", ctx do
    {subscription, checkout} = open_checkout!(ctx.owner, ctx.gym.id, ctx.version)
    StripeFake.complete_checkout(checkout.stripe_session_id)
    {:ok, :activated} = Reconciliation.reconcile_subscription(subscription.id)

    tables =
      ~w(gym_saas_subscriptions stripe_subscriptions stripe_invoices stripe_refunds stripe_disputes
         stripe_webhook_events stripe_checkouts billing_activation_evidence saas_plan_versions)

    snapshot = fn ->
      Map.new(tables, fn t ->
        %{rows: [[n, latest]]} =
          Repo.query!(
            "SELECT count(*), max(updated_at_or_inserted) FROM (SELECT *, " <>
              updated(t) <> " AS updated_at_or_inserted FROM #{t}) x"
          )

        {t, {n, latest}}
      end)
    end

    before = snapshot.()
    requests = length(StripeFake.requests())
    link_before = Repo.get_by!(SubscriptionLink, subscription_id: subscription.id)

    now = DateTime.utc_now()

    concurrently(
      for mode <- [:test, :live] do
        fn ->
          Oversight.overview(mode, now)
          Oversight.reconciliation(mode, 50, nil, now)
          Oversight.invoices_page(%{mode: mode}, 50, nil)
          Oversight.subscriptions_page(%{environment: mode}, 50, nil, now)
        end
      end ++ [fn -> Oversight.plans() end, fn -> read(subscription.id) end]
    )

    assert snapshot.() == before
    assert length(StripeFake.requests()) == requests
    assert Repo.get_by!(SubscriptionLink, subscription_id: subscription.id) == link_before
  end

  defp updated(table) when table in ~w(stripe_webhook_events billing_activation_evidence),
    do: "inserted_at"

  defp updated(_table), do: "updated_at"
end
