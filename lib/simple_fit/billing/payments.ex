defmodule SimpleFit.Billing.Payments do
  @moduledoc """
  A gym's Stripe-backed SaaS billing (SF-102): hosted checkout for a
  pending SF-101 subscription intent, the Stripe Customer Portal, the
  billing summary and invoice history, the reconciliation a returning
  browser asks for, and cancellation synchronized with Stripe. The owner
  acts for the gym (`manage_billing`); every other role is `403`, a stranger
  `404`.

  ## Checkout and idempotency

  1. In the gym write transaction (session held, gym and staff membership
     locked, the subscription `FOR UPDATE`) the intent must be pending, its
     price version mapped to a Stripe Price of the configured mode that
     agrees on currency, amount and interval (a client never names a Stripe
     Price), and live mode never sells a provisional price. A `creating`
     or `open` checkout row is reused; otherwise one is written with a fresh
     idempotency key. Concurrent requests serialize on the subscription.
  2. Outside it, the gym's Stripe Customer is created once (idempotency key
     per gym and mode) and the Checkout Session is created with the row's
     idempotency key: a retry after a lost answer returns the session
     Stripe already made, never a second payable session.
  3. The session id and URL are stored (`open`) and the URL returned. A row
     whose answer was lost past its window can never be paid (nobody holds
     its URL) and is marked `failed` by reconciliation.

  A redirect back from Stripe is not a payment: the browser asks
  `reconcile/4`, which reads Stripe; only a paid invoice activates.

  ## Cancellation

  Stripe first, then SF-101: `immediate` cancels the Stripe Subscription
  now (no proration, no refund), `period_end` sets `cancel_at_period_end`;
  a pending intent's open checkout is expired. Only then the SF-101
  transition is written. If Stripe is unreachable nothing changes locally
  (a local cancellation would let Stripe keep charging).
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.{Clock, Gyms, Repo}

  alias SimpleFit.Billing.{
    GymSubscription,
    PlanVersion,
    PriceVersion,
    Reconciliation,
    Subscriptions
  }

  alias SimpleFit.Billing.Stripe.{
    Checkout,
    Client,
    Config,
    Customer,
    Invoice,
    PriceMapping,
    SubscriptionLink
  }

  @unlogged [log: false]
  @live_statuses [:incomplete, :trialing, :active, :past_due, :unpaid, :paused]

  @type error ::
          :not_found
          | :forbidden
          | :session_revoked
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | SimpleFit.Provider.error()

  ## Reads

  @doc """
  The gym's billing summary: provider readiness, the current subscription
  with its provider-reconciled payment state, the open checkout and what the
  owner can do.
  """
  @spec summary(User.t(), term()) :: {:ok, map()} | {:error, :not_found | :forbidden}
  def summary(%User{} = user, gym_id) do
    with {:ok, access} <- Gyms.authorize(user, gym_id, :manage_billing) do
      {:ok, build_summary(access.gym.id)}
    end
  end

  @doc "The gym's Stripe invoices as last reconciled, newest first (at most 50)."
  @spec invoices(User.t(), term()) :: {:ok, [Invoice.t()]} | {:error, :not_found | :forbidden}
  def invoices(%User{} = user, gym_id) do
    with {:ok, access} <- Gyms.authorize(user, gym_id, :manage_billing) do
      {:ok,
       Repo.all(
         from(i in Invoice,
           where: i.gym_id == ^access.gym.id and i.mode in ^modes(),
           order_by: [desc: i.provider_created_at, desc: i.id],
           limit: 50
         ),
         @unlogged
       )}
    end
  end

  ## Checkout

  @doc "Creates (or returns) the hosted Checkout Session of a pending intent (see the moduledoc)."
  @spec create_checkout(User.t(), Session.t(), term(), term()) ::
          {:ok, {Checkout.t(), :created | :existing}} | {:error, error()}
  def create_checkout(%User{} = user, %Session{} = session, gym_id, subscription_id) do
    with {:ok, config} <- provider(),
         {:ok, plan} <-
           Gyms.billing_write(
             user,
             session,
             gym_id,
             :manage_billing,
             &prepare_checkout(&1, user, subscription_id, config)
           ) do
      case plan do
        {:existing, checkout} ->
          {:ok, {checkout, :existing}}

        {:create, checkout, mapping, customer} ->
          open_checkout(checkout, mapping, customer, config)
      end
    end
  end

  defp prepare_checkout(access, user, subscription_id, config) do
    now = Clock.utc_now()

    with {:ok, subscription} <- lock_subscription(access.gym.id, subscription_id),
         :ok <- pending(subscription),
         {:ok, mapping} <- checkout_price(subscription, config.mode) do
      plan = %{
        gym_id: access.gym.id,
        user: user,
        subscription: subscription,
        mapping: mapping,
        customer: Repo.get_by(Customer, [mode: config.mode, gym_id: access.gym.id], @unlogged),
        config: config,
        now: now
      }

      reuse_or_new(current_checkout(subscription.id, config.mode), plan)
    end
  end

  # An open session is returned while it has time left; a `creating` row
  # (its answer was lost) is retried with the same key while Stripe still
  # accepts the requested expiry (30 minutes ahead). Otherwise a new row.
  defp reuse_or_new(%Checkout{status: :open} = checkout, plan) do
    if DateTime.compare(checkout.expires_at, DateTime.add(plan.now, 60)) == :gt,
      do: {:ok, {:existing, checkout}},
      else: new_checkout(plan, checkout)
  end

  defp reuse_or_new(%Checkout{status: :creating} = checkout, plan) do
    if DateTime.diff(checkout.expires_at, plan.now) > 31 * 60,
      do: {:ok, {:create, checkout, plan.mapping, plan.customer}},
      else: new_checkout(plan, checkout)
  end

  defp reuse_or_new(nil, plan), do: new_checkout(plan, nil)

  defp new_checkout(plan, previous) do
    if previous,
      do: change!(previous, status: if(previous.status == :open, do: :expired, else: :failed))

    checkout =
      Repo.insert!(
        %Checkout{
          mode: plan.config.mode,
          gym_id: plan.gym_id,
          subscription_id: plan.subscription.id,
          idempotency_key: Ecto.UUID.generate(),
          status: :creating,
          expires_at: DateTime.add(plan.now, plan.config.checkout_ttl),
          requested_by_user_id: plan.user.id
        },
        @unlogged
      )

    Subscriptions.audit_billing!(plan.subscription, :saas_checkout_started, checkout.id, plan.now)
    {:ok, {:create, checkout, plan.mapping, plan.customer}}
  end

  defp open_checkout(checkout, mapping, customer, config) do
    with {:ok, customer} <- ensure_customer(customer, checkout.gym_id, config.mode),
         {:ok, session} <-
           Client.post(
             "/v1/checkout/sessions",
             checkout_params(checkout, mapping, customer, config),
             :checkout_session,
             idempotency_key: "simplefit-checkout-" <> checkout.idempotency_key
           ) do
      fn -> store_session(checkout, session, customer) end
      |> Repo.transaction(@unlogged)
      |> opened()
    end
  end

  defp opened({:ok, checkout}), do: {:ok, {checkout, :created}}
  defp opened(error), do: error

  defp store_session(checkout, session, customer) do
    locked =
      Repo.one!(from(c in Checkout, where: c.id == ^checkout.id, lock: "FOR UPDATE"), @unlogged)

    cond do
      session.client_reference_id != checkout.subscription_id or
          session.customer != customer.stripe_customer_id ->
        Repo.rollback({:conflict, %{checkout: "provider_mismatch"}})

      locked.status in [:creating, :open] ->
        change!(locked,
          status: :open,
          stripe_session_id: session.id,
          url: session.url,
          expires_at: session.expires_at || locked.expires_at
        )

      true ->
        # Cancelled meanwhile: the session must not stay payable.
        _ = expire_session(session.id)
        Repo.rollback({:conflict, %{checkout: Atom.to_string(locked.status)}})
    end
  end

  defp checkout_params(checkout, mapping, customer, _config) do
    return = "#{web_app_url()}/app/gyms/#{checkout.gym_id}/settings/plan"

    %{
      mode: "subscription",
      customer: customer.stripe_customer_id,
      client_reference_id: checkout.subscription_id,
      line_items: [%{price: mapping.stripe_price_id, quantity: 1}],
      success_url: return <> "?checkout=returned",
      cancel_url: return <> "?checkout=cancelled",
      expires_at: DateTime.to_unix(checkout.expires_at),
      billing_address_collection: "required",
      metadata: %{
        simplefit_subscription_id: checkout.subscription_id,
        simplefit_gym_id: checkout.gym_id
      },
      subscription_data: %{
        metadata: %{
          simplefit_subscription_id: checkout.subscription_id,
          simplefit_gym_id: checkout.gym_id
        }
      }
    }
  end

  # The gym's Stripe Customer, created once per mode. The idempotency key is
  # per gym and mode, so concurrent first checkouts create one customer.
  defp ensure_customer(%Customer{} = customer, _gym_id, _mode), do: {:ok, customer}

  defp ensure_customer(nil, gym_id, mode) do
    with {:ok, created} <-
           Client.post(
             "/v1/customers",
             %{metadata: %{simplefit_gym_id: gym_id, simplefit_mode: mode}},
             :customer,
             idempotency_key: "simplefit-customer-#{mode}-#{gym_id}"
           ) do
      Repo.insert!(
        %Customer{mode: mode, gym_id: gym_id, stripe_customer_id: created.id},
        Keyword.merge(@unlogged, on_conflict: :nothing)
      )

      case Repo.get_by(Customer, [mode: mode, gym_id: gym_id], @unlogged) do
        %Customer{stripe_customer_id: id} = customer when id == created.id -> {:ok, customer}
        _ -> {:error, :unavailable}
      end
    end
  end

  # The intent's Stripe Price: mapped in this mode and agreeing with the
  # immutable price version; live mode never sells a provisional price.
  defp checkout_price(subscription, mode) do
    price = Repo.get!(PriceVersion, subscription.price_version_id, @unlogged)
    version = Repo.get!(PlanVersion, subscription.plan_version_id, @unlogged)

    case Repo.get_by(PriceMapping, [mode: mode, price_version_id: price.id], @unlogged) do
      nil ->
        {:error, {:conflict, %{stripe_price: "not_mapped"}}}

      %PriceMapping{} = mapping
      when mapping.amount_minor != price.amount_minor or mapping.currency != price.currency or
             mapping.interval != price.interval ->
        {:error, {:conflict, %{stripe_price: "mismatch"}}}

      %PriceMapping{} when mode == :live and version.price_source == :provisional ->
        {:error, {:conflict, %{saas_plan_version: "provisional"}}}

      %PriceMapping{} = mapping ->
        {:ok, mapping}
    end
  end

  ## Portal

  @doc """
  A short-lived Stripe Customer Portal session for the gym's customer
  (payment method, billing history, invoices; plan changes and cancellation
  stay in SimpleFit). The URL is returned, never stored.
  """
  @spec create_portal_session(User.t(), Session.t(), term()) ::
          {:ok, String.t()} | {:error, error()}
  def create_portal_session(%User{} = user, %Session{} = session, gym_id) do
    with {:ok, config} <- provider(),
         {:ok, customer} <-
           Gyms.billing_write(user, session, gym_id, :manage_billing, &gym_customer(&1, config)),
         :ok <- portal_configured(config),
         {:ok, %{url: url}} <-
           Client.post(
             "/v1/billing_portal/sessions",
             %{
               customer: customer.stripe_customer_id,
               configuration: config.portal_configuration_id,
               return_url: "#{web_app_url()}/app/gyms/#{customer.gym_id}/settings/plan"
             },
             :portal_session
           ) do
      {:ok, url}
    end
  end

  defp gym_customer(access, config) do
    case Repo.get_by(Customer, [mode: config.mode, gym_id: access.gym.id], @unlogged) do
      nil -> {:error, {:conflict, %{billing_portal: "no_customer"}}}
      customer -> {:ok, customer}
    end
  end

  defp portal_configured(%{portal_configuration_id: id}) when is_binary(id), do: :ok
  defp portal_configured(_), do: {:error, {:conflict, %{billing_portal: "not_configured"}}}

  ## Reconcile on return

  @doc """
  Reads the gym's subscription state from Stripe now (the return from
  checkout, or a manual refresh) and answers the summary. Rate limited as a
  billing write.
  """
  @spec reconcile(User.t(), Session.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def reconcile(%User{} = user, %Session{} = session, gym_id, subscription_id) do
    with {:ok, _config} <- provider(),
         {:ok, subscription} <-
           Gyms.billing_write(user, session, gym_id, :manage_billing, fn access ->
             find_subscription(access.gym.id, subscription_id)
           end) do
      case Reconciliation.reconcile_subscription(subscription.id) do
        {:error, reason} -> {:error, reason}
        _ok_or_ignored -> {:ok, build_summary(subscription.gym_id)}
      end
    end
  end

  ## Cancellation

  @doc "Cancels the gym's subscription at Stripe first, then in SF-101 (see the moduledoc)."
  @spec cancel(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, GymSubscription.t()} | {:error, error() | Ecto.Changeset.t()}
  def cancel(%User{} = user, %Session{} = session, gym_id, subscription_id, attrs) do
    with {:ok, access} <- Gyms.authorize(user, gym_id, :manage_billing),
         {:ok, subscription} <- find_subscription(access.gym.id, subscription_id),
         :ok <- cancel_at_provider(subscription, attrs) do
      Subscriptions.cancel(user, session, gym_id, subscription_id, attrs)
    end
  end

  defp cancel_at_provider(%GymSubscription{status: status} = subscription, attrs)
       when status in [:pending_activation, :active, :cancellation_scheduled] do
    link = Repo.get_by(SubscriptionLink, [subscription_id: subscription.id], @unlogged)
    checkout = live_checkout(subscription.id)

    case {link, checkout} do
      {nil, nil} ->
        :ok

      {nil, %Checkout{} = c} ->
        with {:ok, config} <- provider(), do: expire_checkout(c, config)

      {%SubscriptionLink{} = l, _} ->
        with {:ok, _} <- provider(), do: cancel_link(l, subscription, attrs)
    end
  end

  defp cancel_at_provider(_subscription, _attrs), do: :ok

  defp cancel_link(%SubscriptionLink{provider_status: status}, _subscription, _attrs)
       when status not in @live_statuses,
       do: :ok

  defp cancel_link(link, subscription, attrs) do
    case {cancel_mode(attrs), subscription.status} do
      {:immediate, _} -> cancel_now(link)
      {:period_end, :pending_activation} -> cancel_now(link)
      {:period_end, :active} -> cancel_at_period_end(link, subscription)
      # Already scheduled, or an invalid mode (SF-101 answers 422).
      _ -> :ok
    end
  end

  defp cancel_mode(attrs) do
    case attrs["mode"] || attrs[:mode] do
      mode when mode in ["immediate", :immediate] -> :immediate
      mode when mode in ["period_end", :period_end] -> :period_end
      _ -> :invalid
    end
  end

  # Ends the Stripe subscription now: no proration, no final invoice, no refund.
  defp cancel_now(link) do
    id = Client.id!(link.stripe_subscription_id, "sub")

    case Client.delete(
           "/v1/subscriptions/#{id}",
           %{invoice_now: false, prorate: false},
           :subscription
         ) do
      {:ok, _} -> :ok
      {:error, :invalid_request} -> already_canceled(id)
      error -> error
    end
  end

  defp cancel_at_period_end(link, subscription) do
    id = Client.id!(link.stripe_subscription_id, "sub")

    with {:ok, _} <-
           Client.post("/v1/subscriptions/#{id}", %{cancel_at_period_end: true}, :subscription,
             idempotency_key: "simplefit-cancel-#{link.id}-#{subscription.revision}"
           ),
         do: :ok
  end

  defp already_canceled(id) do
    case Client.get("/v1/subscriptions/#{id}", %{}, :subscription) do
      {:ok, %{status: status}} when status in [:canceled, :incomplete_expired] -> :ok
      {:ok, _} -> {:error, :unavailable}
      error -> error
    end
  end

  # A pending intent's open checkout is expired before the intent ends; if
  # it completed meanwhile, reconciliation records the payment and the owner
  # retries against the now provider-backed subscription.
  defp expire_checkout(%Checkout{status: :creating} = checkout, _config) do
    change!(checkout, status: :failed)
    :ok
  end

  defp expire_checkout(%Checkout{} = checkout, _config) do
    case expire_session(checkout.stripe_session_id) do
      {:ok, %{status: :expired}} ->
        change!(checkout, status: :expired)
        :ok

      {:ok, %{status: :complete}} ->
        _ = Reconciliation.reconcile_subscription(checkout.subscription_id)
        {:error, {:conflict, %{checkout: "completed"}}}

      {:ok, _} ->
        {:error, :unavailable}

      {:error, :invalid_request} ->
        _ = Reconciliation.reconcile_subscription(checkout.subscription_id)
        {:error, {:conflict, %{checkout: "completed"}}}

      error ->
        error
    end
  end

  defp expire_session(session_id),
    do:
      Client.post(
        "/v1/checkout/sessions/#{Client.id!(session_id, "cs")}/expire",
        %{},
        :checkout_session
      )

  ## Summary

  defp build_summary(gym_id) do
    status = Config.status()
    mode = ready_mode(status)

    subscription =
      Repo.one(
        from(s in GymSubscription,
          where: s.gym_id == ^gym_id,
          order_by: [desc: s.requested_at, desc: s.id],
          limit: 1,
          preload: [plan_version: :plan, price_version: []]
        ),
        @unlogged
      )

    link =
      subscription && Repo.get_by(SubscriptionLink, [subscription_id: subscription.id], @unlogged)

    checkout = subscription && latest_checkout(subscription.id)

    invoice =
      link && link.latest_invoice_id &&
        Repo.get_by(
          Invoice,
          [stripe_invoice_id: link.latest_invoice_id, mode: link.mode],
          @unlogged
        )

    customer = mode && Repo.get_by(Customer, [mode: mode, gym_id: gym_id], @unlogged)

    %{
      provider: %{
        status: provider_state(status),
        mode: mode,
        portal_available: customer != nil and portal_ready?(status)
      },
      subscription: subscription,
      payment: payment_state(subscription, link, checkout, invoice),
      checkout:
        if(match?(%Checkout{status: :open}, checkout),
          do: %{status: :open, expires_at: checkout.expires_at}
        )
    }
  end

  defp ready_mode({:ready, config}), do: config.mode
  defp ready_mode(_status), do: nil

  defp provider_state(:disabled), do: :disabled
  defp provider_state({:misconfigured, _}), do: :unavailable
  defp provider_state({:ready, _}), do: :ready

  defp portal_ready?({:ready, %{portal_configuration_id: id}}), do: is_binary(id)
  defp portal_ready?(_), do: false

  # What the owner sees about payment, from reconciled provider state only.
  defp payment_state(nil, _link, _checkout, _invoice), do: %{state: :none}

  defp payment_state(%GymSubscription{status: status}, _link, _checkout, _invoice)
       when status in [:cancelled, :expired],
       do: %{state: :ended}

  defp payment_state(%GymSubscription{status: :pending_activation}, nil, checkout, _invoice) do
    case checkout do
      %Checkout{status: :open} -> %{state: :checkout_open}
      %Checkout{status: :completed} -> %{state: :processing}
      _ -> %{state: :awaiting_checkout}
    end
  end

  defp payment_state(%GymSubscription{} = s, %SubscriptionLink{} = link, _checkout, invoice) do
    open_invoice = if match?(%Invoice{status: :open}, invoice), do: invoice
    state = linked_state(s.status, link.provider_status, open_invoice)

    %{
      state: state,
      provider_status: link.provider_status,
      next_payment_at: next_payment_at(state, link),
      action_url:
        if(state in [:action_required, :payment_failed, :past_due] and open_invoice != nil,
          do: open_invoice.hosted_invoice_url
        )
    }
  end

  defp linked_state(:pending_activation, _provider, %Invoice{payment_status: :requires_action}),
    do: :action_required

  defp linked_state(:pending_activation, _provider, %Invoice{
         payment_status: :requires_payment_method
       }),
       do: :payment_failed

  defp linked_state(:pending_activation, _provider, _invoice), do: :processing

  defp linked_state(_status, provider, _invoice) when provider in [:past_due, :unpaid],
    do: :past_due

  defp linked_state(:cancellation_scheduled, _provider, _invoice), do: :cancellation_scheduled
  defp linked_state(_status, _provider, _invoice), do: :active

  # Only a provider-confirmed, renewing subscription has a next payment date.
  defp next_payment_at(
         :active,
         %SubscriptionLink{provider_status: :active, cancel_at_period_end: false} = link
       ),
       do: link.current_period_end

  defp next_payment_at(_state, _link), do: nil

  ## Helpers

  defp provider do
    case Config.status() do
      {:ready, config} -> {:ok, config}
      :disabled -> {:error, {:conflict, %{payment_provider: "disabled"}}}
      {:misconfigured, _} -> {:error, :configuration_error}
    end
  end

  defp modes do
    case Config.mode() do
      nil -> [:test, :live]
      mode -> [mode]
    end
  end

  defp lock_subscription(gym_id, subscription_id) do
    with {:ok, id} <- Ecto.UUID.cast(subscription_id),
         %GymSubscription{} = s <-
           Repo.one(
             from(s in GymSubscription,
               where: s.id == ^id and s.gym_id == ^gym_id,
               lock: "FOR UPDATE"
             ),
             @unlogged
           ) do
      {:ok, s}
    else
      _ -> {:error, :not_found}
    end
  end

  defp find_subscription(gym_id, subscription_id) do
    with {:ok, id} <- Ecto.UUID.cast(subscription_id),
         %GymSubscription{} = s <-
           Repo.get_by(GymSubscription, [id: id, gym_id: gym_id], @unlogged) do
      {:ok, s}
    else
      _ -> {:error, :not_found}
    end
  end

  defp pending(%GymSubscription{status: :pending_activation} = s) do
    if Repo.exists?(from(l in SubscriptionLink, where: l.subscription_id == ^s.id)),
      do: {:error, {:conflict, %{checkout: "completed"}}},
      else: :ok
  end

  defp pending(%GymSubscription{status: status}),
    do: {:error, {:conflict, %{saas_subscription: Atom.to_string(status)}}}

  defp current_checkout(subscription_id, mode),
    do:
      Repo.one(
        from(c in Checkout,
          where:
            c.subscription_id == ^subscription_id and c.mode == ^mode and
              c.status in [:creating, :open]
        ),
        @unlogged
      )

  defp live_checkout(subscription_id),
    do:
      Repo.one(
        from(c in Checkout,
          where: c.subscription_id == ^subscription_id and c.status in [:creating, :open]
        ),
        @unlogged
      )

  defp latest_checkout(subscription_id),
    do:
      Repo.one(
        from(c in Checkout,
          where: c.subscription_id == ^subscription_id,
          order_by: [desc: c.inserted_at],
          limit: 1
        ),
        @unlogged
      )

  defp change!(struct, changes),
    do: struct |> Ecto.Changeset.change(changes) |> Repo.update!(@unlogged)

  defp web_app_url,
    do: :simple_fit |> Application.get_env(SimpleFit.Gyms, []) |> Keyword.fetch!(:web_app_url)
end
