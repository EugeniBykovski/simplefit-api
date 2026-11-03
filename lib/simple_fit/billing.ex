defmodule SimpleFit.Billing do
  @moduledoc """
  SimpleFit's SaaS commerce (SF-101; SF-82 05 concept C; D-G09): the plans
  SimpleFit sells to gyms, their immutable price versions, a gym's
  subscription lifecycle and the payment verification boundary. Independent
  of a gym's own member products (`SimpleFit.Gyms` commerce) and of gym
  membership.

  * `SimpleFit.Billing.Catalog` - the operator workflow for plans (drafts,
    provisional seed, publication under an approval). No HTTP write.
  * `SimpleFit.Billing.Subscriptions` - a gym's subscription intent,
    cancellation and period end; the owner acts for the gym.
  * `SimpleFit.Billing.Activation` - the only way to `active`: verified
    evidence from a configured trusted provider (none exists yet, D-G10).

  No payment, invoice, refund, tax or provider call exists anywhere.
  """

  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Billing.{Catalog, GymSubscription, PlanVersion, Subscriptions}

  @doc "The published SaaS catalog (any signed-in user; nothing is public until approved)."
  @spec published_plans() :: [PlanVersion.t()]
  defdelegate published_plans, to: Catalog, as: :published

  @doc "See `SimpleFit.Billing.Subscriptions.list/2`."
  @spec list_gym_subscriptions(User.t(), term()) ::
          {:ok, [GymSubscription.t()]} | {:error, :not_found | :forbidden}
  defdelegate list_gym_subscriptions(user, gym_id), to: Subscriptions, as: :list

  @doc "See `SimpleFit.Billing.Subscriptions.request/4`."
  @spec request_gym_subscription(User.t(), Session.t(), term(), map()) ::
          {:ok, {GymSubscription.t(), :created | :existing}} | {:error, Subscriptions.error()}
  defdelegate request_gym_subscription(user, session, gym_id, attrs),
    to: Subscriptions,
    as: :request

  @doc "See `SimpleFit.Billing.Subscriptions.cancel/5`."
  @spec cancel_gym_subscription(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, GymSubscription.t()} | {:error, Subscriptions.error()}
  defdelegate cancel_gym_subscription(user, session, gym_id, subscription_id, attrs),
    to: Subscriptions,
    as: :cancel
end
