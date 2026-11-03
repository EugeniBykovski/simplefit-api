defmodule SimpleFitWeb.BillingJSON do
  @moduledoc """
  JSON rendering of SimpleFit plans, a gym's subscriptions and its
  entitlements (SF-101). Amounts are decimal strings with their currency and
  integer minor units (`SimpleFit.Money`); never a float. No provider
  reference, approval reference, operator name or payment detail is rendered.
  """

  alias SimpleFit.Billing.{GymSubscription, PlanVersion, PriceVersion}
  alias SimpleFit.Billing.Stripe.{Checkout, Invoice}
  alias SimpleFit.Money

  @lifecycle ~w(requested_at activated_at current_period_start current_period_end cancel_mode
                cancel_reason cancellation_requested_at cancellation_effective_at ended_at)a

  def plans(%{plans: plans}), do: %{plans: Enum.map(plans, &plan/1)}

  def subscriptions(%{subscriptions: list}),
    do: %{subscriptions: Enum.map(list, &subscription_json/1)}

  def subscription(%{subscription: s}), do: %{subscription: subscription_json(s)}

  def summary(%{summary: summary}) do
    %{
      billing: %{
        provider: summary.provider,
        subscription: summary.subscription && subscription_json(summary.subscription),
        payment:
          Map.merge(
            %{provider_status: nil, next_payment_at: nil, action_url: nil},
            summary.payment
          ),
        checkout: summary.checkout
      }
    }
  end

  def invoices(%{invoices: invoices}), do: %{invoices: Enum.map(invoices, &invoice_json/1)}

  def checkout(%{checkout: %Checkout{} = c}),
    do: %{checkout: %{checkout_id: c.id, status: c.status, url: c.url, expires_at: c.expires_at}}

  def portal(%{url: url}), do: %{portal: %{url: url}}

  def entitlements(%{projection: %{subscription: sub, features: features}}),
    do: %{
      subscription: sub,
      features:
        Enum.map(
          features,
          &Map.take(&1, [:key, :description, :enforced, :status, :reason, :quantity_limit])
        )
    }

  defp plan(%PlanVersion{} = v) do
    %{
      plan_key: v.plan.key,
      plan_version_id: v.id,
      version: v.version,
      name: v.name,
      description: v.description,
      price_source: v.price_source,
      proposed_trial_days: v.proposed_trial_days,
      published_at: v.published_at,
      prices: Enum.map(v.prices, &price/1),
      entitlements:
        Enum.map(
          v.entitlements,
          &%{feature_key: &1.feature_key, quantity_limit: &1.quantity_limit}
        )
    }
  end

  defp price(%PriceVersion{} = p) do
    %{
      price_version_id: p.id,
      interval: p.interval,
      currency: p.currency,
      pricing: p.pricing,
      amount: p.amount_minor && Money.format(p.amount_minor, p.currency),
      amount_minor: p.amount_minor
    }
  end

  defp invoice_json(%Invoice{} = i) do
    %{
      invoice_id: i.id,
      number: i.number,
      status: i.status,
      payment_status: i.payment_status,
      currency: i.currency,
      total: money(i.total, i.currency),
      total_minor: i.total,
      amount_paid: money(i.amount_paid, i.currency),
      amount_paid_minor: i.amount_paid,
      amount_refunded: money(i.amount_refunded, i.currency),
      amount_refunded_minor: i.amount_refunded,
      disputed: i.disputed,
      period_start: i.period_start,
      period_end: i.period_end,
      issued_at: i.provider_created_at,
      paid_at: i.paid_at,
      hosted_invoice_url: i.hosted_invoice_url,
      invoice_pdf: i.invoice_pdf,
      subscription_id: i.subscription_id,
      mode: i.mode
    }
  end

  # A currency SimpleFit does not support is shown in minor units only.
  defp money(minor, currency) when is_integer(minor) and minor >= 0 do
    if Money.currency?(currency), do: Money.format(minor, currency)
  end

  defp money(_minor, _currency), do: nil

  defp subscription_json(%GymSubscription{} = s) do
    s
    |> Map.take(@lifecycle)
    |> Map.merge(%{
      subscription_id: s.id,
      gym_id: s.gym_id,
      status: s.status,
      plan: %{
        plan_key: s.plan_version.plan.key,
        plan_version_id: s.plan_version.id,
        version: s.plan_version.version,
        name: s.plan_version.name
      },
      price: price(s.price_version)
    })
  end
end
