defmodule SimpleFitWeb.GymCommerceJSON do
  @moduledoc """
  JSON rendering of a gym's member products and product subscriptions
  (SF-101). Views are the projections built by `SimpleFit.Gyms`; fields are
  picked explicitly. Amounts are decimal strings with their currency and
  integer minor units; never a float. A member sees offers and their own
  subscriptions; staff also see a short member name, never an email.
  """

  alias SimpleFit.Money

  @product ~w(product_id gym_id key product_type status created_at retired_at)a
  @version ~w(version_id version status name description class_credits validity_days published_at)a
  @offer_version ~w(version_id version name description class_credits validity_days)a
  @subscription ~w(subscription_id gym_id gym_member_id status product requested_at activated_at
                   current_period_start current_period_end cancel_mode cancel_reason
                   cancellation_requested_at cancellation_effective_at ended_at)a

  def products(%{products: products}), do: %{products: Enum.map(products, &product_json/1)}

  def product(%{product: view}), do: %{product: product_json(view)}

  def offers(%{products: products}), do: %{products: Enum.map(products, &offer/1)}

  def subscriptions(%{page: %{entries: entries, next_cursor: cursor}}),
    do: %{subscriptions: Enum.map(entries, &subscription_json/1), next_cursor: cursor}

  def subscription(%{subscription: view}), do: %{subscription: subscription_json(view)}

  defp product_json(view) do
    view
    |> Map.take(@product)
    |> Map.merge(%{
      published: view.published && version(view.published),
      draft: view.draft && version(view.draft),
      versions: Enum.map(view.versions, &version/1)
    })
  end

  defp version(view) do
    view
    |> Map.take(@version)
    |> Map.merge(%{
      current_prices: Enum.map(view.current_prices, &price/1),
      prices: Enum.map(view.prices, &price/1)
    })
  end

  defp offer(view) do
    %{
      product_id: view.product_id,
      key: view.key,
      product_type: view.product_type,
      published:
        view.published
        |> Map.take(@offer_version)
        |> Map.put(:current_prices, Enum.map(view.published.current_prices, &price/1))
    }
  end

  defp subscription_json(view) do
    view
    |> Map.take(@subscription)
    |> Map.put(:price, price(view.price))
    |> then(fn json ->
      if Map.has_key?(view, :member_name),
        do: Map.put(json, :member_name, view.member_name),
        else: json
    end)
  end

  defp price(view) do
    %{
      price_version_id: view.price_version_id,
      currency: view.currency,
      amount: Money.format(view.amount_minor, view.currency),
      amount_minor: view.amount_minor,
      sequence: view.sequence,
      created_at: view.created_at
    }
  end
end
