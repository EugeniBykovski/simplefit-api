defmodule SimpleFit.StripeHelpers do
  @moduledoc """
  Fixtures for SF-102 Stripe billing tests, through the public contexts and
  the deterministic `SimpleFit.StripeFake`: a published plan with its price
  mapped to a (fake) Stripe Price, a pending intent with an open checkout,
  signed webhook deliveries and their processing.
  """

  import Ecto.Query, only: [from: 2]
  import SimpleFit.BillingHelpers

  alias SimpleFit.{Billing, GymHelpers, Repo, StripeFake}
  alias SimpleFit.Billing.{Operations, Webhooks}
  alias SimpleFit.Billing.Stripe.{Signature, WebhookEvent}

  @secret "whsec_notarealsecret"

  @doc "The test webhook secret (a placeholder)."
  def webhook_secret, do: @secret

  @doc "A published plan whose month price is mapped to a Stripe Price."
  def mapped_plan!(key \\ plan_key("stripe")) do
    version = published_plan!(%{}, key)
    {:ok, mapping} = Operations.map_price(price(version).id, operator())
    {version, mapping}
  end

  @doc "A pending intent of `owner`'s gym with an open hosted checkout."
  def open_checkout!(owner, gym_id, version) do
    subscription = pending_saas!(owner, gym_id, version)
    {:ok, {checkout, :created}} = checkout(owner, gym_id, subscription.id)
    {subscription, checkout}
  end

  @doc "Creates (or returns) the hosted checkout as `user` (raw result)."
  def checkout(user, gym_id, subscription_id),
    do: Billing.create_gym_checkout(user, GymHelpers.live_session!(user), gym_id, subscription_id)

  @doc "Signs and ingests a Stripe event body as the webhook endpoint would (raw result)."
  def deliver(event, opts \\ []) do
    raw = Jason.encode!(event)
    timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
    signature = Keyword.get(opts, :signature, Signature.sign(raw, @secret, timestamp))
    Webhooks.ingest(raw, signature, event)
  end

  @doc "Delivers an event and processes its inbox row (the Oban job, inline)."
  def deliver_and_process!(event) do
    {:ok, _} = deliver(event)
    process_event!(event["id"])
  end

  @doc "Processes the inbox row of `stripe_event_id`."
  def process_event!(stripe_event_id) do
    %WebhookEvent{id: id} = Repo.get_by!(WebhookEvent, stripe_event_id: stripe_event_id)
    Webhooks.process(id)
  end

  @doc "The inbox row of an event."
  def inbox(stripe_event_id), do: Repo.get_by(WebhookEvent, stripe_event_id: stripe_event_id)

  @doc "Inbox rows for an event id."
  def inbox_count(stripe_event_id),
    do:
      Repo.aggregate(
        from(e in WebhookEvent, where: e.stripe_event_id == ^stripe_event_id),
        :count
      )

  @doc "The checkout session id of a checkout row."
  def session_id(checkout), do: checkout.stripe_session_id

  @doc "Completes the checkout at Stripe and delivers the events Stripe would send."
  def pay_checkout!(checkout, outcome \\ :paid) do
    ids = StripeFake.complete_checkout(checkout.stripe_session_id, outcome)

    deliver_and_process!(
      StripeFake.event(
        "checkout.session.completed",
        "checkout.session",
        checkout.stripe_session_id
      )
    )

    ids
  end
end
