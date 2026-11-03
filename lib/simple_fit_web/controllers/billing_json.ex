defmodule SimpleFitWeb.BillingJSON do
  @moduledoc """
  JSON rendering of SimpleFit plans, a gym's subscriptions and its
  entitlements (SF-101). Amounts are decimal strings with their currency and
  integer minor units (`SimpleFit.Money`); never a float. No provider
  reference, approval reference, operator name or payment detail is rendered.
  """

  alias SimpleFit.Billing.{GymSubscription, PlanVersion, PriceVersion}
  alias SimpleFit.Money

  @lifecycle ~w(requested_at activated_at current_period_start current_period_end cancel_mode
                cancel_reason cancellation_requested_at cancellation_effective_at ended_at)a

  def plans(%{plans: plans}), do: %{plans: Enum.map(plans, &plan/1)}

  def subscriptions(%{subscriptions: list}),
    do: %{subscriptions: Enum.map(list, &subscription_json/1)}

  def subscription(%{subscription: s}), do: %{subscription: subscription_json(s)}

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
