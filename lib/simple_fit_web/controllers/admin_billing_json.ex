defmodule SimpleFitWeb.AdminBillingJSON do
  @moduledoc """
  Renders the operator billing views (SF-127): allowlisted fields only. Every amount is
  integer minor units of its own currency plus the same amount as a decimal string
  (`nil` for a currency SimpleFit doesn't list); sums carry their minor units as a
  string too, since a total may outgrow a JSON number's exact range.
  """

  alias SimpleFit.Billing.Oversight

  def overview(%{overview: o}) do
    %{
      overview: %{
        observed_at: o.observed_at,
        mode: o.mode,
        configured_mode: o.configured_mode,
        integration: o.integration,
        subscriptions: o.subscriptions,
        unrecorded_subscriptions: o.unrecorded_subscriptions,
        provider_statuses: o.provider_statuses,
        invoices: o.invoices,
        payment_issues: o.payment_issues,
        refunds: o.refunds,
        disputes: Enum.map(o.disputes, fn {status, count} -> %{status: status, count: count} end),
        collected: %{
          period_start: o.collected.period_start,
          period_end: o.collected.period_end,
          currencies: Enum.map(o.collected.currencies, &collected/1)
        },
        last_synced_at: o.last_synced_at,
        last_webhook_at: o.last_webhook_at,
        unavailable: Enum.map(o.unavailable, &%{metric: &1, reason: "no_approved_definition"})
      }
    }
  end

  def plans(%{plans: plans}), do: %{plans: Enum.map(plans, &plan_json/1)}

  def plan(%{plan: plan}), do: %{plan: plan_json(plan)}

  def subscriptions(%{page: page}) do
    %{
      mode: page.mode,
      subscriptions: Enum.map(page.subscriptions, &subscription_json/1),
      next_cursor: page.next_cursor
    }
  end

  def subscription(%{subscription: s}) do
    %{
      subscription:
        s
        |> subscription_json()
        |> Map.merge(%{
          revision: s.revision,
          cancel_mode: s.cancel_mode,
          cancellation_requested_at: s.cancellation_requested_at,
          provider_period_start: s.provider_period_start,
          provider_period_end: s.provider_period_end,
          periods: s.periods,
          invoices: Enum.map(s.invoices, &detail_invoice/1),
          checkouts: s.checkouts
        })
    }
  end

  def invoices(%{page: page}) do
    %{
      mode: page.mode,
      invoices: Enum.map(page.invoices, &Map.put(invoice_json(&1), :gym, &1.gym)),
      next_cursor: page.next_cursor
    }
  end

  def reconciliation(%{reconciliation: r}) do
    %{
      reconciliation: %{
        observed_at: r.observed_at,
        mode: r.mode,
        integration: r.integration,
        summary: r.summary,
        webhooks: r.webhooks,
        discrepancies: r.discrepancies,
        next_cursor: r.next_cursor
      }
    }
  end

  defp collected(c) do
    %{
      currency: c.currency,
      invoice_count: c.invoice_count,
      amount_paid: Oversight.decimal(c.amount_paid_minor, c.currency),
      amount_paid_minor: Integer.to_string(c.amount_paid_minor),
      amount_refunded: Oversight.decimal(c.amount_refunded_minor, c.currency),
      amount_refunded_minor: Integer.to_string(c.amount_refunded_minor)
    }
  end

  defp plan_json(plan) do
    %{
      key: plan.key,
      created_at: plan.created_at,
      current_version_id: plan.current_version_id,
      versions: Enum.map(plan.versions, &version/1)
    }
  end

  defp version(v) do
    v
    |> Map.take([
      :id,
      :version,
      :name,
      :description,
      :status,
      :price_source,
      :proposed_trial_days,
      :approval_reference,
      :published_at,
      :superseded_at,
      :retired_at,
      :archived_at,
      :created_at,
      :entitlements
    ])
    |> Map.put(:prices, Enum.map(v.prices, &price/1))
  end

  defp price(p) do
    %{
      price_version_id: p.id,
      interval: p.interval,
      currency: p.currency,
      pricing: p.pricing,
      amount: Oversight.decimal(p.amount_minor, p.currency),
      amount_minor: p.amount_minor,
      stripe_mapped_modes: p.stripe_mapped_modes
    }
  end

  defp subscription_json(s) do
    s
    |> Map.take([
      :id,
      :gym,
      :status,
      :environment,
      :plan,
      :requested_at,
      :activated_at,
      :current_period_start,
      :current_period_end,
      :cancel_reason,
      :cancellation_effective_at,
      :ended_at,
      :provider_status,
      :cancel_at_period_end,
      :reconciliation
    ])
    |> Map.put(:price, %{
      interval: s.price.interval,
      currency: s.price.currency,
      pricing: s.price.pricing,
      amount: Oversight.decimal(s.price.amount_minor, s.price.currency),
      amount_minor: s.price.amount_minor
    })
  end

  defp detail_invoice(i) do
    i
    |> invoice_json()
    |> Map.merge(%{
      refunds: Enum.map(i.refunds, &with_amount/1),
      disputes: Enum.map(i.disputes, &with_amount/1)
    })
  end

  defp with_amount(row),
    do: Map.put(row, :amount, Oversight.decimal(row.amount_minor, row.currency))

  defp invoice_json(i) do
    i
    |> Map.take([
      :id,
      :mode,
      :number,
      :subscription_id,
      :status,
      :payment_status,
      :issue,
      :currency,
      :total_minor,
      :amount_due_minor,
      :amount_paid_minor,
      :amount_remaining_minor,
      :amount_refunded_minor,
      :disputed,
      :billing_reason,
      :period_start,
      :period_end,
      :issued_at,
      :paid_at,
      :attempt_count,
      :next_payment_attempt_at,
      :synced_at
    ])
    |> Map.merge(%{
      total: Oversight.decimal(i.total_minor, i.currency),
      amount_due: Oversight.decimal(i.amount_due_minor, i.currency),
      amount_paid: Oversight.decimal(i.amount_paid_minor, i.currency),
      amount_remaining: Oversight.decimal(i.amount_remaining_minor, i.currency),
      amount_refunded: Oversight.decimal(i.amount_refunded_minor, i.currency)
    })
  end
end
