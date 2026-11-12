defmodule SimpleFit.Billing.Oversight do
  @moduledoc """
  Platform operator oversight of SimpleFit's SaaS billing (SF-127): read-only
  projections owned by the Billing context, reached only through
  `SimpleFit.Operators` (`billing.read`, `billing.reconciliation.read`). Nothing here
  writes, calls Stripe or computes a price: every figure is a count or a sum of rows
  SF-101 and SF-102 already recorded, and the docs name its source
  (`docs/architecture/billing-oversight-metrics.md`).

  ## Environments

  Every Stripe row names its mode, and a projection reads exactly one: `:test` or
  `:live`, never both, never one standing in for the other. An SF-101 subscription
  has no mode of its own; it is classified by its Stripe Subscription link, else by
  its latest hosted checkout, else `:none` (no provider record: an intent nobody
  paid, or one activated by another trusted provider). `:none` is its own group,
  never added to a mode.

  ## Money

  Amounts stay integer minor units of their own currency. Sums are per mode and per
  currency, never converted or added across currencies, and named for what they are
  (`amount_paid` of paid Stripe invoices, gross): not revenue. MRR, ARR, recognized or
  net revenue and churn have no approved definition and are reported as unavailable.

  ## Reconciliation

  There is no reconciliation run: each subscription's Stripe link records the
  provider state last read (`synced_at`) and a `discrepancy` code when it could not be
  applied. A link is `in_sync` (no discrepancy at its last read, within the sweep's six
  hours), `stale` (older), or `mismatch`; a subscription with a checkout but no link
  yet is `not_linked`, one with no provider record `not_evaluated`. "No discrepancy" is
  only ever said about a link that was read.

  Never returned: Stripe object or customer ids, hosted invoice or checkout URLs,
  webhook payloads, payment method details, or anything about a gym's people.
  """

  import Ecto.Query, only: [from: 2, subquery: 1]

  alias SimpleFit.Billing.{GymSubscription, Plan, PlanEntitlement, PlanVersion, PriceVersion}
  alias SimpleFit.Billing.SubscriptionPeriod

  alias SimpleFit.Billing.Stripe.{
    Checkout,
    Config,
    Dispute,
    Invoice,
    PriceMapping,
    Refund,
    SubscriptionLink,
    WebhookEvent
  }

  alias SimpleFit.{Gyms, Money, Repo}

  @unlogged [log: false]

  @modes [:test, :live]
  @collected_days 30
  @stale_seconds 6 * 3600
  @plan_limit 100
  @detail_invoices 24
  @detail_periods 50
  @detail_checkouts 10
  @failed_events 20

  @unavailable ~w(mrr arr recognized_revenue net_revenue churn ltv forecast fx_total)

  @type mode :: :test | :live
  @type environment :: mode() | :none
  @type position :: {DateTime.t(), Ecto.UUID.t()} | nil

  @doc "The Stripe modes a projection can read."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "The subscription statuses (SF-101)."
  @spec subscription_statuses() :: [atom()]
  def subscription_statuses, do: GymSubscription.statuses()

  @doc "The invoice statuses and payment statuses (Stripe's, as recorded)."
  @spec invoice_statuses() :: {[atom()], [atom()]}
  def invoice_statuses, do: {Invoice.statuses(), Invoice.payment_statuses()}

  @doc "Metrics no projection reports, and why: none has an approved definition."
  @spec unavailable_metrics() :: [String.t()]
  def unavailable_metrics, do: @unavailable

  @doc """
  The mode this deployment is configured for (`STRIPE_MODE`, `:test` unless set),
  whether or not the integration is enabled: the default a projection reads.
  """
  @spec configured_mode() :: mode()
  def configured_mode do
    case Application.get_env(:simple_fit, SimpleFit.Billing.Stripe, [])[:mode] do
      :live -> :live
      _ -> :test
    end
  end

  @doc "The Stripe integration's state: `:disabled`, `:misconfigured` or `:ready`."
  @spec integration() :: :disabled | :misconfigured | :ready
  def integration do
    case Config.status() do
      :disabled -> :disabled
      {:misconfigured, _} -> :misconfigured
      {:ready, _} -> :ready
    end
  end

  ## Overview

  @doc """
  The billing overview of one mode at `now`: subscriptions by status (and, apart,
  those with no provider record), Stripe subscription states, invoices by status,
  open payment issues, refunds and disputes by status, the `amount_paid` of invoices
  paid in the last #{@collected_days} days per currency, and when the mode's data was
  last synced or a webhook last arrived. Each figure is its own query, not one
  atomic snapshot.
  """
  @spec overview(mode(), DateTime.t()) :: map()
  def overview(mode, %DateTime{} = now) when mode in @modes do
    since = DateTime.add(now, -@collected_days * 86_400)

    %{
      observed_at: now,
      mode: mode,
      configured_mode: configured_mode(),
      integration: integration(),
      subscriptions: subscription_counts(Atom.to_string(mode)),
      unrecorded_subscriptions: subscription_counts("none"),
      provider_statuses:
        counts(
          from(l in SubscriptionLink,
            where: l.mode == ^mode,
            group_by: l.provider_status,
            select: {l.provider_status, count()}
          ),
          SubscriptionLink.provider_statuses()
        ),
      invoices:
        counts(
          from(i in Invoice,
            where: i.mode == ^mode,
            group_by: i.status,
            select: {i.status, count()}
          ),
          Invoice.statuses()
        ),
      payment_issues: payment_issues(mode),
      refunds:
        counts(
          from(r in Refund,
            where: r.mode == ^mode,
            group_by: r.status,
            select: {r.status, count()}
          ),
          Refund.statuses()
        ),
      disputes:
        from(d in Dispute,
          where: d.mode == ^mode,
          group_by: d.status,
          order_by: d.status,
          select: {d.status, count()}
        )
        |> Repo.all(@unlogged),
      collected: %{period_start: since, period_end: now, currencies: collected(mode, since, now)},
      last_synced_at: last_synced_at(mode),
      last_webhook_at:
        Repo.one(
          from(e in WebhookEvent, where: e.mode == ^mode, select: max(e.inserted_at)),
          @unlogged
        ),
      unavailable: @unavailable
    }
  end

  defp subscription_counts(environment) do
    from(s in subquery(classified()),
      where: s.environment == ^environment,
      group_by: s.status,
      select: {s.status, count()}
    )
    |> counts(GymSubscription.statuses())
  end

  defp counts(query, keys) do
    found = query |> Repo.all(@unlogged) |> Map.new()
    Map.new(keys, &{&1, Map.get(found, &1, 0)})
  end

  # Open invoices whose last payment attempt failed or needs the customer, and
  # invoices Stripe marked uncollectible. A failed attempt is not a final failure:
  # Stripe may retry (`next_payment_attempt_at`).
  defp payment_issues(mode) do
    from(i in Invoice,
      where: i.mode == ^mode,
      select: %{
        payment_failed:
          filter(
            count(i.id),
            i.status == :open and i.payment_status == :requires_payment_method
          ),
        action_required:
          filter(count(i.id), i.status == :open and i.payment_status == :requires_action),
        uncollectible: filter(count(i.id), i.status == :uncollectible)
      }
    )
    |> Repo.one(@unlogged)
  end

  # Gross `amount_paid` of invoices paid in the window, per currency, with what Stripe
  # has refunded of those same invoices so far; summed in PostgreSQL (numeric), so a
  # total never passes through a float.
  defp collected(mode, since, now) do
    from(i in Invoice,
      where: i.mode == ^mode and i.status == :paid and i.paid_at >= ^since and i.paid_at <= ^now,
      group_by: i.currency,
      order_by: i.currency,
      select: {i.currency, count(), sum(i.amount_paid), sum(i.amount_refunded)}
    )
    |> Repo.all(@unlogged)
    |> Enum.map(fn {currency, count, paid, refunded} ->
      %{
        currency: currency,
        invoice_count: count,
        amount_paid_minor: to_integer(paid),
        amount_refunded_minor: to_integer(refunded)
      }
    end)
  end

  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(nil), do: 0

  defp last_synced_at(mode) do
    [
      Repo.one(
        from(l in SubscriptionLink, where: l.mode == ^mode, select: max(l.synced_at)),
        @unlogged
      ),
      Repo.one(from(i in Invoice, where: i.mode == ^mode, select: max(i.synced_at)), @unlogged)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  ## Plan catalog

  @doc """
  The SaaS plan catalog (at most #{@plan_limit} plans, by key): each plan with every
  version, newest first, its prices and the modes its prices are mapped to Stripe in.
  Versions are shown as recorded; nothing is recomputed from a newer version.
  """
  @spec plans() :: [map()]
  def plans do
    plans = Repo.all(from(p in Plan, order_by: p.key, limit: @plan_limit), @unlogged)
    versions = versions_of(Enum.map(plans, & &1.id), false)
    Enum.map(plans, &plan_view(&1, Map.get(versions, &1.id, [])))
  end

  @doc "One plan by key with its full version history and entitlements, or `nil`."
  @spec plan(String.t()) :: map() | nil
  def plan(key) when is_binary(key) do
    case Repo.get_by(Plan, [key: key], @unlogged) do
      nil -> nil
      plan -> plan_view(plan, Map.get(versions_of([plan.id], true), plan.id, []))
    end
  end

  defp plan_view(plan, versions) do
    current = Enum.find(versions, &(&1.status == :published))

    %{
      key: plan.key,
      created_at: plan.inserted_at,
      current_version_id: current && current.id,
      versions: versions
    }
  end

  defp versions_of([], _entitlements?), do: %{}

  defp versions_of(plan_ids, entitlements?) do
    versions =
      Repo.all(
        from(v in PlanVersion,
          where: v.plan_id in ^plan_ids,
          order_by: [asc: v.plan_id, desc: v.version]
        ),
        @unlogged
      )

    ids = Enum.map(versions, & &1.id)
    prices = prices_of(ids)
    entitlements = if entitlements?, do: entitlements_of(ids), else: %{}

    versions
    |> Enum.map(&version_view(&1, Map.get(prices, &1.id, []), Map.get(entitlements, &1.id)))
    |> Enum.group_by(& &1.plan_id)
  end

  defp version_view(v, prices, entitlements) do
    %{
      id: v.id,
      plan_id: v.plan_id,
      version: v.version,
      name: v.name,
      description: v.description,
      status: v.status,
      price_source: v.price_source,
      proposed_trial_days: v.proposed_trial_days,
      approval_reference: v.approval_reference,
      published_at: v.published_at,
      superseded_at: v.superseded_at,
      retired_at: v.retired_at,
      archived_at: v.archived_at,
      created_at: v.inserted_at,
      prices: prices,
      entitlements: entitlements
    }
  end

  defp prices_of(version_ids) do
    mapped =
      from(m in PriceMapping,
        join: p in PriceVersion,
        on: p.id == m.price_version_id,
        where: p.plan_version_id in ^version_ids,
        order_by: m.mode,
        select: {m.price_version_id, m.mode}
      )
      |> Repo.all(@unlogged)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    from(p in PriceVersion,
      where: p.plan_version_id in ^version_ids,
      order_by: [asc: p.currency, asc: p.interval]
    )
    |> Repo.all(@unlogged)
    |> Enum.group_by(
      & &1.plan_version_id,
      &%{
        id: &1.id,
        interval: &1.interval,
        currency: &1.currency,
        pricing: &1.pricing,
        amount_minor: &1.amount_minor,
        stripe_mapped_modes: Map.get(mapped, &1.id, [])
      }
    )
  end

  defp entitlements_of(version_ids) do
    from(e in PlanEntitlement,
      where: e.plan_version_id in ^version_ids,
      order_by: e.feature_key
    )
    |> Repo.all(@unlogged)
    |> Enum.group_by(
      & &1.plan_version_id,
      &%{feature_key: &1.feature_key, quantity_limit: &1.quantity_limit}
    )
  end

  ## Subscriptions

  @typedoc "A subscription list filter."
  @type subscription_filters :: %{
          required(:environment) => environment(),
          optional(:status) => atom(),
          optional(:plan_key) => String.t(),
          optional(:plan_version_id) => Ecto.UUID.t(),
          optional(:gym_id) => Ecto.UUID.t()
        }

  @doc """
  One page of gym SaaS subscriptions of one environment, newest request first:
  `{rows, next}` where `next` is the position `{requested_at, id}` after the last row,
  or `nil` on the last page.
  """
  @spec subscriptions_page(subscription_filters(), pos_integer(), position(), DateTime.t()) ::
          {[map()], position()}
  def subscriptions_page(filters, limit, position, %DateTime{} = now) do
    rows =
      Enum.reduce(filters, subscription_query(), fn
        {:environment, env}, q -> from([c: c] in q, where: c.environment == ^Atom.to_string(env))
        {:status, status}, q -> from([s: s] in q, where: s.status == ^status)
        {:plan_key, key}, q -> from([p: p] in q, where: p.key == ^key)
        {:plan_version_id, id}, q -> from([v: v] in q, where: v.id == ^id)
        {:gym_id, id}, q -> from([s: s] in q, where: s.gym_id == ^id)
      end)
      |> after_position(position)
      |> then(
        &from([s: s] in &1, order_by: [desc: s.requested_at, desc: s.id], limit: ^(limit + 1))
      )
      |> Repo.all(@unlogged)

    {page, more} = Enum.split(rows, limit)
    next = if more == [], do: nil, else: page |> List.last() |> then(&{&1.requested_at, &1.id})
    {subscription_views(page, now), next}
  end

  @doc """
  One gym SaaS subscription with its billing periods, its recorded Stripe invoices
  (newest #{@detail_invoices}) with their refunds and disputes, and its hosted
  checkouts' states (newest #{@detail_checkouts}), or `nil`.
  """
  @spec subscription(Ecto.UUID.t(), DateTime.t()) :: map() | nil
  def subscription(id, %DateTime{} = now) do
    case Repo.one(from([s: s] in subscription_query(), where: s.id == ^id), @unlogged) do
      nil ->
        nil

      row ->
        [view] = subscription_views([row], now)
        invoices = subscription_invoices(id)

        Map.merge(view, %{
          revision: row.revision,
          cancel_mode: row.cancel_mode,
          cancellation_requested_at: row.cancellation_requested_at,
          provider_period_start: row.link_period_start,
          provider_period_end: row.link_period_end,
          periods: periods(id),
          invoices: invoices,
          checkouts: checkouts(id)
        })
    end
  end

  defp subscription_query do
    latest_checkout =
      from(c in Checkout,
        where: c.subscription_id == parent_as(:s).id,
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: 1,
        select: %{mode: c.mode}
      )

    from(s in GymSubscription,
      as: :s,
      join: c in subquery(classified()),
      as: :c,
      on: c.id == s.id,
      join: v in PlanVersion,
      as: :v,
      on: v.id == s.plan_version_id,
      join: p in Plan,
      as: :p,
      on: p.id == v.plan_id,
      join: pr in PriceVersion,
      as: :pr,
      on: pr.id == s.price_version_id,
      left_join: l in SubscriptionLink,
      as: :l,
      on: l.subscription_id == s.id,
      left_lateral_join: lc in subquery(latest_checkout),
      on: true,
      select: %{
        id: s.id,
        gym_id: s.gym_id,
        status: s.status,
        environment: c.environment,
        requested_at: s.requested_at,
        activated_at: s.activated_at,
        current_period_start: s.current_period_start,
        current_period_end: s.current_period_end,
        cancel_mode: s.cancel_mode,
        cancel_reason: s.cancel_reason,
        cancellation_requested_at: s.cancellation_requested_at,
        cancellation_effective_at: s.cancellation_effective_at,
        ended_at: s.ended_at,
        revision: s.revision,
        plan_key: p.key,
        plan_version_id: v.id,
        plan_version: v.version,
        plan_name: v.name,
        plan_version_status: v.status,
        interval: pr.interval,
        currency: pr.currency,
        pricing: pr.pricing,
        amount_minor: pr.amount_minor,
        provider_status: l.provider_status,
        cancel_at_period_end: l.cancel_at_period_end,
        discrepancy: l.discrepancy,
        synced_at: l.synced_at,
        link_period_start: l.current_period_start,
        link_period_end: l.current_period_end,
        has_link: not is_nil(l.id),
        checkout_mode: lc.mode
      }
    )
  end

  # Each subscription's environment: its Stripe link's mode, else its latest
  # checkout's, else `none`. One link per subscription (unique index).
  defp classified do
    from(s in GymSubscription,
      left_join: l in SubscriptionLink,
      on: l.subscription_id == s.id,
      select: %{
        id: s.id,
        status: s.status,
        environment:
          fragment(
            "COALESCE(?, (SELECT c.mode FROM stripe_checkouts c WHERE c.subscription_id = ? ORDER BY c.inserted_at DESC, c.id DESC LIMIT 1), 'none')",
            l.mode,
            s.id
          )
      }
    )
  end

  defp after_position(query, nil), do: query

  defp after_position(query, {at, id}),
    do:
      from([s: s] in query,
        where: s.requested_at < ^at or (s.requested_at == ^at and s.id < ^id)
      )

  defp subscription_views(rows, now) do
    names = Gyms.oversight_names(Enum.map(rows, & &1.gym_id))

    Enum.map(rows, fn row ->
      %{
        id: row.id,
        gym: %{id: row.gym_id, name: Map.get(names, row.gym_id)},
        status: row.status,
        environment: String.to_existing_atom(row.environment),
        plan: %{
          key: row.plan_key,
          plan_version_id: row.plan_version_id,
          version: row.plan_version,
          name: row.plan_name,
          version_status: row.plan_version_status
        },
        price: %{
          interval: row.interval,
          currency: row.currency,
          pricing: row.pricing,
          amount_minor: row.amount_minor
        },
        requested_at: row.requested_at,
        activated_at: row.activated_at,
        current_period_start: row.current_period_start,
        current_period_end: row.current_period_end,
        cancel_reason: row.cancel_reason,
        cancellation_effective_at: row.cancellation_effective_at,
        ended_at: row.ended_at,
        provider_status: row.provider_status,
        cancel_at_period_end: row.has_link && row.cancel_at_period_end,
        reconciliation: reconciliation_state(row, now)
      }
    end)
  end

  defp reconciliation_state(%{has_link: true} = row, now) do
    state =
      cond do
        row.discrepancy != nil -> :mismatch
        stale?(row.synced_at, row.provider_status, now) -> :stale
        true -> :in_sync
      end

    %{state: state, discrepancy: row.discrepancy, synced_at: row.synced_at}
  end

  defp reconciliation_state(%{checkout_mode: mode}, _now) when not is_nil(mode),
    do: %{state: :not_linked, discrepancy: nil, synced_at: nil}

  defp reconciliation_state(_row, _now),
    do: %{state: :not_evaluated, discrepancy: nil, synced_at: nil}

  # The hourly sweep re-reads every link not synced for six hours that hasn't ended at
  # Stripe; an ended one is never re-read, so its age says nothing.
  defp stale?(synced_at, provider_status, now) do
    provider_status not in [:canceled, :incomplete_expired] and
      DateTime.diff(now, synced_at) > @stale_seconds
  end

  defp periods(subscription_id) do
    from(p in SubscriptionPeriod,
      where: p.subscription_id == ^subscription_id,
      order_by: [desc: p.period_start],
      limit: @detail_periods,
      select: %{
        period_start: p.period_start,
        period_end: p.period_end,
        source: p.source,
        recorded_at: p.inserted_at
      }
    )
    |> Repo.all(@unlogged)
  end

  defp subscription_invoices(subscription_id) do
    invoices =
      Repo.all(
        from(i in Invoice,
          where: i.subscription_id == ^subscription_id,
          order_by: [desc: i.provider_created_at, desc: i.id],
          limit: @detail_invoices
        ),
        @unlogged
      )

    ids = Enum.map(invoices, & &1.id)

    refunds =
      from(r in Refund, where: r.invoice_id in ^ids, order_by: [asc: r.inserted_at])
      |> Repo.all(@unlogged)
      |> Enum.group_by(& &1.invoice_id, &refund_view/1)

    disputes =
      from(d in Dispute, where: d.invoice_id in ^ids, order_by: [asc: d.inserted_at])
      |> Repo.all(@unlogged)
      |> Enum.group_by(& &1.invoice_id, &dispute_view/1)

    Enum.map(invoices, fn invoice ->
      invoice
      |> invoice_view()
      |> Map.merge(%{
        refunds: Map.get(refunds, invoice.id, []),
        disputes: Map.get(disputes, invoice.id, [])
      })
    end)
  end

  defp refund_view(r) do
    %{
      origin: r.origin,
      status: r.status,
      amount_minor: r.amount_minor,
      currency: r.currency,
      reason: r.reason,
      created_at: r.inserted_at,
      synced_at: r.synced_at
    }
  end

  defp dispute_view(d) do
    %{
      status: d.status,
      reason: d.reason,
      amount_minor: d.amount_minor,
      currency: d.currency,
      created_at: d.inserted_at,
      synced_at: d.synced_at
    }
  end

  defp checkouts(subscription_id) do
    from(c in Checkout,
      where: c.subscription_id == ^subscription_id,
      order_by: [desc: c.inserted_at, desc: c.id],
      limit: @detail_checkouts,
      select: %{
        mode: c.mode,
        status: c.status,
        created_at: c.inserted_at,
        expires_at: c.expires_at,
        completed_at: c.completed_at
      }
    )
    |> Repo.all(@unlogged)
  end

  ## Invoices

  @typedoc "An invoice list filter."
  @type invoice_filters :: %{
          required(:mode) => mode(),
          optional(:status) => atom(),
          optional(:payment_status) => atom(),
          optional(:issue) => :any | :payment_failed | :action_required | :uncollectible,
          optional(:currency) => String.t(),
          optional(:gym_id) => Ecto.UUID.t()
        }

  @doc """
  One page of recorded Stripe invoices of one mode, newest first (Stripe's creation
  time): `{rows, next}`, `next` being `{provider_created_at, id}` or `nil`.
  """
  @spec invoices_page(invoice_filters(), pos_integer(), position()) :: {[map()], position()}
  def invoices_page(filters, limit, position) do
    rows =
      Enum.reduce(filters, from(i in Invoice, as: :i), fn
        {:mode, mode}, q -> from([i: i] in q, where: i.mode == ^mode)
        {:status, status}, q -> from([i: i] in q, where: i.status == ^status)
        {:payment_status, ps}, q -> from([i: i] in q, where: i.payment_status == ^ps)
        {:currency, currency}, q -> from([i: i] in q, where: i.currency == ^currency)
        {:gym_id, id}, q -> from([i: i] in q, where: i.gym_id == ^id)
        {:issue, issue}, q -> issue_filter(q, issue)
      end)
      |> invoice_after(position)
      |> then(
        &from([i: i] in &1,
          order_by: [desc: i.provider_created_at, desc: i.id],
          limit: ^(limit + 1)
        )
      )
      |> Repo.all(@unlogged)

    {page, more} = Enum.split(rows, limit)

    next =
      if more == [], do: nil, else: page |> List.last() |> then(&{&1.provider_created_at, &1.id})

    names = Gyms.oversight_names(Enum.map(page, & &1.gym_id))

    {Enum.map(
       page,
       &Map.put(invoice_view(&1), :gym, %{id: &1.gym_id, name: Map.get(names, &1.gym_id)})
     ), next}
  end

  defp issue_filter(q, :payment_failed),
    do:
      from([i: i] in q, where: i.status == :open and i.payment_status == :requires_payment_method)

  defp issue_filter(q, :action_required),
    do: from([i: i] in q, where: i.status == :open and i.payment_status == :requires_action)

  defp issue_filter(q, :uncollectible), do: from([i: i] in q, where: i.status == :uncollectible)

  defp issue_filter(q, :any),
    do:
      from([i: i] in q,
        where:
          (i.status == :open and i.payment_status in [:requires_payment_method, :requires_action]) or
            i.status == :uncollectible
      )

  defp invoice_after(query, nil), do: query

  defp invoice_after(query, {at, id}),
    do:
      from([i: i] in query,
        where: i.provider_created_at < ^at or (i.provider_created_at == ^at and i.id < ^id)
      )

  defp invoice_view(%Invoice{} = i) do
    %{
      id: i.id,
      mode: i.mode,
      number: i.number,
      subscription_id: i.subscription_id,
      status: i.status,
      payment_status: i.payment_status,
      issue: issue(i),
      currency: i.currency,
      total_minor: i.total,
      amount_due_minor: i.amount_due,
      amount_paid_minor: i.amount_paid,
      amount_remaining_minor: i.amount_remaining,
      amount_refunded_minor: i.amount_refunded,
      disputed: i.disputed,
      billing_reason: i.billing_reason,
      period_start: i.period_start,
      period_end: i.period_end,
      issued_at: i.provider_created_at,
      paid_at: i.paid_at,
      attempt_count: i.attempt_count,
      next_payment_attempt_at: i.next_payment_attempt_at,
      synced_at: i.synced_at
    }
  end

  @doc "An invoice's payment issue, as Stripe recorded it, or `nil`."
  @spec issue(Invoice.t()) :: :payment_failed | :action_required | :uncollectible | nil
  def issue(%Invoice{status: :open, payment_status: :requires_payment_method}),
    do: :payment_failed

  def issue(%Invoice{status: :open, payment_status: :requires_action}), do: :action_required
  def issue(%Invoice{status: :uncollectible}), do: :uncollectible
  def issue(%Invoice{}), do: nil

  ## Reconciliation

  @doc """
  Reconciliation of one mode at `now`: links by state, subscriptions waiting for a
  link, when links were last and least recently read, the webhook inbox (counts by
  status over 24 hours, the unprocessed backlog, the newest #{@failed_events} failed
  events' type and outcome code), and one page of links with a discrepancy, most
  recently read first (`{synced_at, link id}` positions).
  """
  @spec reconciliation(mode(), pos_integer(), position(), DateTime.t()) :: map()
  def reconciliation(mode, limit, position, %DateTime{} = now) when mode in @modes do
    stale_before = DateTime.add(now, -@stale_seconds)
    {discrepancies, next} = discrepancy_page(mode, limit, position)

    links =
      from(l in SubscriptionLink,
        where: l.mode == ^mode,
        select: %{
          linked: count(l.id),
          mismatch: filter(count(l.id), not is_nil(l.discrepancy)),
          stale:
            filter(
              count(l.id),
              is_nil(l.discrepancy) and l.synced_at < ^stale_before and
                l.provider_status not in [:canceled, :incomplete_expired]
            ),
          last_synced_at: max(l.synced_at),
          oldest_synced_at: min(l.synced_at)
        }
      )
      |> Repo.one(@unlogged)

    %{
      observed_at: now,
      mode: mode,
      integration: integration(),
      summary:
        links
        |> Map.put(:in_sync, links.linked - links.mismatch - links.stale)
        |> Map.put(:not_linked, not_linked(mode)),
      webhooks: webhooks(mode, now),
      discrepancies: discrepancies,
      next: next
    }
  end

  defp not_linked(mode) do
    Repo.one(
      from(s in GymSubscription,
        left_join: l in SubscriptionLink,
        on: l.subscription_id == s.id,
        where:
          is_nil(l.id) and
            fragment(
              "EXISTS (SELECT 1 FROM stripe_checkouts c WHERE c.subscription_id = ? AND c.mode = ?)",
              s.id,
              ^Atom.to_string(mode)
            ),
        select: count()
      ),
      @unlogged
    )
  end

  defp webhooks(mode, now) do
    since = DateTime.add(now, -86_400)

    counts =
      counts(
        from(e in WebhookEvent,
          where: e.mode == ^mode and e.inserted_at >= ^since,
          group_by: e.status,
          select: {e.status, count()}
        ),
        [:received, :processed, :ignored, :failed]
      )

    %{
      window_start: since,
      counts: counts,
      backlog:
        Repo.one(
          from(e in WebhookEvent,
            where: e.mode == ^mode and e.status == :received,
            select: count()
          ),
          @unlogged
        ),
      last_received_at:
        Repo.one(
          from(e in WebhookEvent, where: e.mode == ^mode, select: max(e.inserted_at)),
          @unlogged
        ),
      failed:
        from(e in WebhookEvent,
          where: e.mode == ^mode and e.status == :failed,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: @failed_events,
          select: %{
            event_type: e.event_type,
            outcome: e.outcome,
            attempts: e.attempts,
            event_created_at: e.event_created_at,
            received_at: e.inserted_at,
            processed_at: e.processed_at
          }
        )
        |> Repo.all(@unlogged)
    }
  end

  defp discrepancy_page(mode, limit, position) do
    rows =
      from(l in SubscriptionLink,
        join: s in GymSubscription,
        on: s.id == l.subscription_id,
        where: l.mode == ^mode and not is_nil(l.discrepancy),
        order_by: [desc: l.synced_at, desc: l.id],
        limit: ^(limit + 1),
        select: %{
          link_id: l.id,
          subscription_id: s.id,
          gym_id: s.gym_id,
          subscription_status: s.status,
          provider_status: l.provider_status,
          discrepancy: l.discrepancy,
          synced_at: l.synced_at
        }
      )
      |> link_after(position)
      |> Repo.all(@unlogged)

    {page, more} = Enum.split(rows, limit)
    next = if more == [], do: nil, else: page |> List.last() |> then(&{&1.synced_at, &1.link_id})
    names = Gyms.oversight_names(Enum.map(page, & &1.gym_id))

    {Enum.map(page, fn row ->
       row
       |> Map.delete(:link_id)
       |> Map.delete(:gym_id)
       |> Map.put(:gym, %{id: row.gym_id, name: Map.get(names, row.gym_id)})
     end), next}
  end

  defp link_after(query, nil), do: query

  defp link_after(query, {at, id}),
    do: from([l] in query, where: l.synced_at < ^at or (l.synced_at == ^at and l.id < ^id))

  @doc "The decimal string of `minor` units of `currency`, or `nil` if SimpleFit doesn't list it."
  @spec decimal(integer() | nil, String.t()) :: String.t() | nil
  def decimal(minor, currency) when is_integer(minor) and minor >= 0 do
    if Money.currency?(currency), do: Money.format(minor, currency)
  end

  def decimal(_minor, _currency), do: nil
end
