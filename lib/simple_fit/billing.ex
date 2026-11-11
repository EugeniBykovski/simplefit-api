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
    evidence from a configured trusted provider.

  SF-102 (Stripe, ADR 0026 amendment SF-102):

  * `SimpleFit.Billing.Payments` - hosted checkout of a pending intent, the
    Customer Portal, the billing summary and invoices, cancellation synced
    with Stripe first.
  * `SimpleFit.Billing.Webhooks` and `SimpleFit.Billing.Reconciliation` -
    signature-verified webhook inbox and the only path from Stripe state to
    SF-101 transitions (activation and renewal from paid invoices).
  * `SimpleFit.Billing.Operations` - operator price mapping, portal
    configuration, full refunds under an approval; `SimpleFit.Billing.Connect`
    - the Connect foundation (no member payment exists).

  Tax is not computed and no invoice is rendered by SimpleFit: invoices are
  Stripe's.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Billing.{Catalog, GymSubscription, Payments, PlanVersion, Subscriptions}
  alias SimpleFit.Billing.Stripe.{Checkout, Invoice, WebhookEvent}
  alias SimpleFit.Repo

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

  @doc "See `SimpleFit.Billing.Payments.cancel/5` (Stripe first, then `Subscriptions.cancel/5`)."
  @spec cancel_gym_subscription(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, GymSubscription.t()} | {:error, Subscriptions.error() | Payments.error()}
  defdelegate cancel_gym_subscription(user, session, gym_id, subscription_id, attrs),
    to: Payments,
    as: :cancel

  @doc "See `SimpleFit.Billing.Payments.summary/2`."
  @spec gym_billing_summary(User.t(), term()) :: {:ok, map()} | {:error, :not_found | :forbidden}
  defdelegate gym_billing_summary(user, gym_id), to: Payments, as: :summary

  @doc "See `SimpleFit.Billing.Payments.invoices/2`."
  @spec list_gym_invoices(User.t(), term()) ::
          {:ok, [Invoice.t()]} | {:error, :not_found | :forbidden}
  defdelegate list_gym_invoices(user, gym_id), to: Payments, as: :invoices

  @doc "See `SimpleFit.Billing.Payments.create_checkout/4`."
  @spec create_gym_checkout(User.t(), Session.t(), term(), term()) ::
          {:ok, {Checkout.t(), :created | :existing}} | {:error, Payments.error()}
  defdelegate create_gym_checkout(user, session, gym_id, subscription_id),
    to: Payments,
    as: :create_checkout

  @doc "See `SimpleFit.Billing.Payments.create_portal_session/3`."
  @spec create_gym_portal_session(User.t(), Session.t(), term()) ::
          {:ok, String.t()} | {:error, Payments.error()}
  defdelegate create_gym_portal_session(user, session, gym_id),
    to: Payments,
    as: :create_portal_session

  @doc "See `SimpleFit.Billing.Payments.reconcile/4`."
  @spec reconcile_gym_subscription(User.t(), Session.t(), term(), term()) ::
          {:ok, map()} | {:error, Payments.error()}
  defdelegate reconcile_gym_subscription(user, session, gym_id, subscription_id),
    to: Payments,
    as: :reconcile

  @doc """
  When the last Stripe webhook event was received (SF-121, the operator health
  card), or `nil`. A receipt time only: it says nothing about whether payments work.
  """
  @spec last_webhook_received_at() :: DateTime.t() | nil
  def last_webhook_received_at do
    Repo.one(from(e in WebhookEvent, select: max(e.inserted_at)))
  end

  @doc """
  Stripe webhook events received since `since`, by processing status, for the
  operator health page (SF-126): counts only, never an event's payload, ids or
  object. Statuses: `received` (not yet processed), `processed`, `ignored`, `failed`.
  """
  @spec webhook_counts(DateTime.t()) :: %{
          optional(:received | :processed | :ignored | :failed) => non_neg_integer()
        }
  def webhook_counts(%DateTime{} = since) do
    from(e in WebhookEvent,
      where: e.inserted_at >= ^since,
      group_by: e.status,
      select: {e.status, count()}
    )
    |> Repo.all(log: false)
    |> Map.new()
  end
end
