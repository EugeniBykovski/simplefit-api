defmodule SimpleFit.Billing.Reconciliation do
  @moduledoc """
  Reconciles SimpleFit's SaaS subscriptions with Stripe (SF-102). The only
  code that turns provider state into SF-101 transitions.

  ## Authority

  Stripe is authoritative for its objects (checkout sessions,
  subscriptions, invoices, refunds, disputes); SimpleFit for gyms, plans,
  prices, the subscription lifecycle and entitlements. Every decision reads
  the object **from the Stripe API with SimpleFit's key** at decision time:
  a webhook only says *which* object to look at, so a forged, replayed,
  duplicated or out-of-order event can never set state (an older event
  re-reads the newest state). Stripe metadata never creates an identity:

  * a Stripe Subscription is linked to an SF-101 subscription only from a
    checkout row SimpleFit created, whose session (read from Stripe) is
    `complete`, references that subscription (`client_reference_id`) and
    the gym's own Stripe Customer;
  * an invoice, refund or dispute belongs to a gym only through the gym's
    Stripe Customer and, for evidence, the linked Stripe Subscription.

  ## Serialization

  Everything that touches one SF-101 subscription runs in one transaction
  holding its row `FOR UPDATE`, and fetches from Stripe inside it: the last
  writer has read the newest provider state, so concurrent webhooks,
  retries, the return from checkout and a cancellation never interleave.
  Unlinked invoices and refunds serialize on their invoice row or a
  transaction advisory lock of their Stripe id.

  ## Rules

  * **Activation / renewal** only from a `paid` invoice of the linked
    Stripe Subscription and the gym's customer, in the price version's
    currency, for exactly its amount, whose subscription line period is not
    over (`SimpleFit.Billing.Stripe.VerifiedInvoice` →
    `SimpleFit.Billing.Stripe.Provider`). Anything else records a
    `discrepancy` code and grants nothing. `checkout.session.completed`,
    a success redirect or Stripe's `active` status alone never activates.
  * **Payment pending / action required / failed**: the subscription stays
    `pending_activation` (or keeps its paid period); the invoice's payment
    status is recorded for the gym's billing page.
  * **Cancellation** at the provider: `cancel_at_period_end` schedules it,
    withdrawing it reactivates, the end cancels (`provider_initiated` when
    SimpleFit did not ask) or expires (ended unpaid).
  * **Refunds and disputes** are recorded truthfully (a dispute is never a
    refund) and audited; neither revokes an entitlement by itself (no
    approved rule).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias SimpleFit.Billing.{GymSubscription, PriceVersion, Subscriptions}

  alias SimpleFit.Billing.Stripe.{
    Checkout,
    Client,
    Config,
    Customer,
    Dispute,
    Invoice,
    PriceMapping,
    Provider,
    Refund,
    SubscriptionLink,
    VerifiedInvoice
  }

  alias SimpleFit.{Clock, Gyms, Repo}

  @unlogged [log: false]

  @type outcome :: {:ok, atom()} | {:ignore, atom()} | {:error, SimpleFit.Provider.error()}

  ## Entry points

  @doc """
  Reconciles one SF-101 subscription with Stripe: its checkout, its Stripe
  Subscription and the given invoices (plus the latest), then applies the
  rules. Used by webhooks, the return from checkout and the periodic sweep.
  """
  @spec reconcile_subscription(term(), [String.t()]) :: outcome()
  def reconcile_subscription(subscription_id, invoice_ids \\ []) do
    with {:ok, config} <- Config.fetch() do
      transaction(fn -> lock_and_reconcile(subscription_id, config.mode, invoice_ids) end)
    end
  end

  defp lock_and_reconcile(subscription_id, mode, invoice_ids) do
    with {:ok, subscription} <- Subscriptions.lock_for_provider(subscription_id) do
      reconcile_locked(subscription, mode, invoice_ids)
    end
  end

  @doc "A Checkout Session event: the subscription of SimpleFit's checkout row, if any."
  @spec sync_checkout_session(String.t()) :: outcome()
  def sync_checkout_session(session_id) do
    with {:ok, config} <- Config.fetch() do
      case Repo.get_by(Checkout, [mode: config.mode, stripe_session_id: session_id], @unlogged) do
        %Checkout{subscription_id: id} -> reconcile_subscription(id)
        nil -> {:ignore, :unknown_checkout}
      end
    end
  end

  @doc """
  A Subscription event: its linked SF-101 subscription; or, before the link
  exists, the gym (through the subscription's customer) whose pending
  intent has a checkout.
  """
  @spec sync_stripe_subscription(String.t()) :: outcome()
  def sync_stripe_subscription(stripe_subscription_id) do
    with {:ok, config} <- Config.fetch() do
      case link_by_stripe_id(config.mode, stripe_subscription_id) do
        %SubscriptionLink{subscription_id: id} -> reconcile_subscription(id)
        nil -> route_unlinked_subscription(config.mode, stripe_subscription_id)
      end
    end
  end

  defp route_unlinked_subscription(mode, stripe_subscription_id) do
    with {:ok, sub} <- fetch_subscription(stripe_subscription_id) do
      route_by_customer(mode, sub.customer, [])
    end
  end

  @doc "An Invoice event: the invoice's subscription, or the invoice alone."
  @spec sync_invoice(String.t()) :: outcome()
  def sync_invoice(invoice_id) do
    with {:ok, config} <- Config.fetch(),
         {:ok, invoice} <- fetch_invoice(invoice_id) do
      route_invoice(config.mode, invoice)
    end
  end

  defp route_invoice(mode, invoice) do
    cond do
      is_nil(customer_gym(mode, invoice.customer)) ->
        {:ignore, :unknown_customer}

      link = invoice.subscription && link_by_stripe_id(mode, invoice.subscription) ->
        reconcile_subscription(link.subscription_id, [invoice.id])

      true ->
        mode
        |> route_by_customer(invoice.customer, [invoice.id])
        |> unlinked_fallback(mode, invoice.id)
    end
  end

  defp unlinked_fallback({:ignore, _}, mode, invoice_id),
    do: record_unlinked_invoice(mode, invoice_id)

  defp unlinked_fallback(outcome, _mode, _invoice_id), do: outcome

  @doc "A PaymentIntent event: the invoices it paid or tried to pay."
  @spec sync_payment_intent(String.t()) :: outcome()
  def sync_payment_intent(payment_intent_id) do
    with {:ok, payments} <- invoice_payments_of(payment_intent_id) do
      payments
      |> Enum.map(& &1.invoice)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> case do
        [] -> {:ignore, :no_invoice}
        ids -> ids |> Enum.map(&sync_invoice/1) |> combine()
      end
    end
  end

  @doc "A Refund event (or a refund listed for a charge)."
  @spec sync_refund(String.t()) :: outcome()
  def sync_refund(refund_id) do
    with {:ok, config} <- Config.fetch(),
         {:ok, refund} <- Client.get("/v1/refunds/#{Client.id!(refund_id, "re")}", %{}, :refund),
         {:ok, invoice} <- invoice_of(config.mode, refund.payment_intent) do
      transaction(fn -> apply_refund(config.mode, invoice, refund) end)
    end
  end

  @doc "A Charge event: every refund of the charge."
  @spec sync_charge_refunds(String.t()) :: outcome()
  def sync_charge_refunds(charge_id) do
    with {:ok, %{data: refunds}} <-
           Client.get("/v1/refunds", %{charge: Client.id!(charge_id, "ch")}, :refunds) do
      case refunds do
        [] -> {:ignore, :no_refund}
        list -> list |> Enum.map(&sync_refund(&1.id)) |> combine()
      end
    end
  end

  @doc "A Dispute event."
  @spec sync_dispute(String.t()) :: outcome()
  def sync_dispute(dispute_id) do
    with {:ok, config} <- Config.fetch(),
         {:ok, dispute} <-
           Client.get("/v1/disputes/#{Client.id!(dispute_id, "d[pu]")}", %{}, :dispute),
         {:ok, invoice} <- invoice_of(config.mode, dispute.payment_intent) do
      transaction(fn -> apply_dispute(config.mode, invoice, dispute) end)
    end
  end

  ## Reconciling one subscription (locked)

  defp reconcile_locked(%GymSubscription{} = subscription, mode, invoice_ids) do
    now = Clock.utc_now()

    with {:ok, link} <- ensure_link(subscription, mode, now) do
      case link do
        nil -> {:ok, :no_provider_subscription}
        %SubscriptionLink{} -> apply_provider(subscription, link, mode, invoice_ids, now)
      end
    end
  end

  # The subscription's link, or one created from its verified, completed
  # checkout. Open checkouts are refreshed on the way.
  defp ensure_link(subscription, mode, now) do
    case Repo.get_by(SubscriptionLink, [subscription_id: subscription.id], @unlogged) do
      %SubscriptionLink{mode: ^mode} = link -> {:ok, link}
      %SubscriptionLink{} -> {:ignore, :other_mode}
      nil -> link_from_checkout(subscription, mode, now)
    end
  end

  defp link_from_checkout(subscription, mode, now) do
    checkout =
      Repo.one(
        from(c in Checkout,
          where:
            c.subscription_id == ^subscription.id and c.mode == ^mode and
              c.status in [:creating, :open, :completed],
          order_by: [desc: c.inserted_at],
          limit: 1
        ),
        @unlogged
      )

    case checkout do
      nil -> {:ok, nil}
      %Checkout{status: :creating} = c -> fail_lost_checkout(c, now)
      %Checkout{} = c -> refresh_checkout(subscription, c, mode, now)
    end
  end

  # A request whose answer never arrived and whose window has passed: no one
  # holds its URL, so it can never be paid.
  defp fail_lost_checkout(%Checkout{} = checkout, now) do
    if DateTime.compare(checkout.expires_at, now) != :gt,
      do: update!(checkout, status: :failed)

    {:ok, nil}
  end

  defp refresh_checkout(subscription, checkout, mode, now) do
    with {:ok, session} <-
           Client.get(
             "/v1/checkout/sessions/#{Client.id!(checkout.stripe_session_id, "cs")}",
             %{},
             :checkout_session
           ) do
      customer = Repo.get_by(Customer, [mode: mode, gym_id: subscription.gym_id], @unlogged)

      if session_owned?(session, subscription, customer) do
        apply_session(session, subscription, checkout, customer, mode, now)
      else
        Logger.warning("checkout session does not match its subscription", reason: :ownership)
        {:ignore, :checkout_mismatch}
      end
    end
  end

  # The session must name this subscription and, once it has a customer,
  # the gym's own customer.
  defp session_owned?(session, subscription, customer) do
    session.client_reference_id == subscription.id and
      (is_nil(session.customer) or
         (customer != nil and session.customer == customer.stripe_customer_id))
  end

  defp apply_session(%{status: :expired}, _subscription, checkout, _customer, _mode, _now) do
    update!(checkout, status: :expired)
    {:ok, nil}
  end

  defp apply_session(
         %{status: :complete, subscription: id},
         subscription,
         checkout,
         customer,
         mode,
         now
       )
       when is_binary(id) do
    if checkout.status != :completed,
      do: update!(checkout, status: :completed, completed_at: now)

    create_link(subscription, id, customer, mode, now)
  end

  defp apply_session(_session, _subscription, _checkout, _customer, _mode, _now), do: {:ok, nil}

  defp create_link(_subscription, _stripe_subscription_id, nil, _mode, _now),
    do: {:ignore, :customer_mismatch}

  defp create_link(subscription, stripe_subscription_id, customer, mode, now) do
    with {:ok, sub} <- fetch_subscription(stripe_subscription_id),
         true <- sub.customer == customer.stripe_customer_id || {:ignore, :customer_mismatch} do
      %SubscriptionLink{
        mode: mode,
        gym_id: subscription.gym_id,
        subscription_id: subscription.id,
        stripe_subscription_id: sub.id,
        stripe_customer_id: customer.stripe_customer_id,
        provider_status: sub.status,
        cancel_at_period_end: sub.cancel_at_period_end,
        current_period_start: sub.current_period_start,
        current_period_end: sub.current_period_end,
        latest_invoice_id: sub.latest_invoice,
        synced_at: now
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:mode, :stripe_subscription_id],
        name: :stripe_subscriptions_mode_stripe_subscription_id_index
      )
      |> Repo.insert(@unlogged)
      |> case do
        {:ok, link} -> {:ok, link}
        {:error, _} -> {:ignore, :subscription_already_linked}
      end
    end
  end

  defp apply_provider(subscription, link, mode, invoice_ids, now) do
    with {:ok, sub} <- fetch_subscription(link.stripe_subscription_id),
         {:ok, mapping, price} <- mapping_for(subscription, mode),
         {:ok, invoices} <- sync_invoices(subscription, link, sub, invoice_ids, mode, now) do
      discrepancy =
        cond do
          sub.customer != link.stripe_customer_id -> "customer_mismatch"
          sub.price != mapping.stripe_price_id or sub.quantity != 1 -> "price_mismatch"
          true -> nil
        end

      link =
        update!(link,
          provider_status: sub.status,
          cancel_at_period_end: sub.cancel_at_period_end,
          current_period_start: sub.current_period_start,
          current_period_end: sub.current_period_end,
          latest_invoice_id: sub.latest_invoice,
          discrepancy: discrepancy,
          synced_at: now
        )

      if discrepancy do
        Logger.warning("provider subscription not applied", reason: discrepancy)
        {:ok, :discrepancy}
      else
        transition(subscription, link, sub, invoices, {mapping, price}, now)
      end
    end
  end

  # SF-101 state from provider state (see the moduledoc).
  defp transition(
         %GymSubscription{status: :pending_activation} = s,
         link,
         sub,
         invoices,
         price,
         now
       ) do
    cond do
      sub.status in [:incomplete_expired, :canceled] ->
        {:ok, _} = Subscriptions.end_by_provider_locked(s, :cancelled, now)
        {:ok, :cancelled}

      sub.status in [:active, :past_due] ->
        activate(s, link, invoices, price, now)

      true ->
        {:ok, :pending}
    end
  end

  defp transition(%GymSubscription{status: :active} = s, link, sub, invoices, price, now) do
    with {:ok, renewed} <- renew_all(s, link, invoices, price, now) do
      settle_active(renewed, sub, now)
    end
  end

  defp transition(
         %GymSubscription{status: :cancellation_scheduled} = s,
         link,
         sub,
         invoices,
         price,
         now
       ) do
    cond do
      sub.status == :canceled ->
        {:ok, _} = Subscriptions.end_by_provider_locked(s, :cancelled, now)
        {:ok, :cancelled}

      not sub.cancel_at_period_end and is_nil(sub.cancel_at) and
          sub.status in [:active, :past_due, :trialing] ->
        {:ok, active} = Subscriptions.reactivate_locked(s, now)
        transition(active, link, sub, invoices, price, now)

      true ->
        {:ok, :cancellation_scheduled}
    end
  end

  defp transition(%GymSubscription{} = _ended, link, sub, _invoices, _price, _now) do
    if sub.status in [:canceled, :incomplete_expired] do
      {:ok, :ended}
    else
      update!(link, discrepancy: "ended_locally_live_at_provider")
      Logger.warning("provider subscription live for an ended subscription", reason: :ended)
      {:ok, :discrepancy}
    end
  end

  # An active subscription after its renewals: ended or scheduled at Stripe.
  defp settle_active(s, %{status: :canceled} = sub, now) do
    outcome = if sub.cancellation_reason == "payment_failed", do: :expired, else: :cancelled
    {:ok, _} = Subscriptions.end_by_provider_locked(s, outcome, now)
    {:ok, outcome}
  end

  defp settle_active(s, sub, now) do
    if sub.cancel_at_period_end or sub.cancel_at != nil do
      effective = sub.cancel_at || sub.current_period_end || s.current_period_end
      {:ok, _} = Subscriptions.schedule_by_provider_locked(s, effective, now)
      {:ok, :cancellation_scheduled}
    else
      {:ok, :active}
    end
  end

  defp activate(subscription, link, invoices, price, now) do
    invoices
    |> Enum.filter(&(&1.status == :paid))
    |> Enum.sort_by(& &1.period_start, DateTime)
    |> Enum.find_value({:ok, :pending}, fn invoice ->
      with {:ok, verified} <- verify(invoice, link, price, now),
           {:ok, _} <- Subscriptions.activate_locked(subscription, Provider, verified, now) do
        {:ok, :activated}
      else
        {:error, reason} ->
          note(link, reason)
          nil
      end
    end)
  end

  defp renew_all(subscription, link, invoices, price, now) do
    invoices
    |> Enum.filter(
      &((&1.status == :paid and &1.period_end) &&
          DateTime.compare(&1.period_end, subscription.current_period_end) == :gt)
    )
    |> Enum.sort_by(& &1.period_start, DateTime)
    |> Enum.reduce_while({:ok, subscription}, fn invoice, {:ok, current} ->
      with {:ok, verified} <- verify(invoice, link, price, now),
           {:ok, renewed} <- Subscriptions.renew_locked(current, Provider, verified, now) do
        {:cont, {:ok, renewed}}
      else
        {:error, reason} ->
          note(link, reason)
          {:cont, {:ok, current}}
      end
    end)
  end

  defp note(_link, :evidence_replayed), do: :ok

  defp note(link, reason) do
    code = if is_atom(reason), do: Atom.to_string(reason), else: "invalid_evidence"
    update!(link, discrepancy: code)
    Logger.warning("provider invoice not applied", reason: code)
  end

  # A paid invoice proves the period only if it is this gym's, of this
  # Stripe Subscription, in the agreed currency and amount, and current.
  defp verify(%Invoice{} = invoice, link, price, now) do
    with :ok <- verify_paid(invoice, link),
         :ok <- verify_amount(invoice, price),
         :ok <- verify_period(invoice, now) do
      {:ok,
       %VerifiedInvoice{
         mode: invoice.mode,
         invoice_id: invoice.stripe_invoice_id,
         status: :paid,
         period_start: invoice.period_start,
         period_end: invoice.period_end
       }}
    end
  end

  defp verify_paid(%Invoice{status: :paid} = invoice, link) do
    if invoice.stripe_subscription_id == link.stripe_subscription_id,
      do: :ok,
      else: {:error, :invoice_subscription_mismatch}
  end

  defp verify_paid(_invoice, _link), do: {:error, :invoice_not_paid}

  defp verify_amount(invoice, {mapping, price}) do
    cond do
      invoice.currency != price.currency or invoice.currency != mapping.currency ->
        {:error, :invoice_currency_mismatch}

      invoice.total != price.amount_minor or invoice.total != mapping.amount_minor ->
        {:error, :invoice_amount_mismatch}

      true ->
        :ok
    end
  end

  defp verify_period(%Invoice{period_start: %DateTime{}, period_end: %DateTime{} = ends}, now) do
    if DateTime.compare(ends, now) == :gt, do: :ok, else: {:error, :invoice_period_over}
  end

  defp verify_period(_invoice, _now), do: {:error, :invoice_period_missing}

  ## Invoices

  # Fetches and records the subscription's latest invoice and `extra` ones;
  # only invoices of the gym's customer and this Stripe Subscription.
  defp sync_invoices(subscription, link, sub, extra, mode, now) do
    [sub.latest_invoice | extra]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case sync_linked_invoice(id, subscription, link, mode, now) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, recorded} -> {:cont, {:ok, [recorded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # One invoice of the link's customer and Stripe Subscription, recorded;
  # another's (or one Stripe does not know for this account) is skipped.
  defp sync_linked_invoice(id, subscription, link, mode, now) do
    case fetch_invoice(id) do
      {:ok, %{customer: customer, subscription: sub} = invoice}
      when customer == link.stripe_customer_id and sub == link.stripe_subscription_id ->
        {:ok, record_invoice!(invoice, subscription, mode, now)}

      {:ok, _other} ->
        Logger.warning("provider invoice of another subscription skipped", reason: :ownership)
        {:ok, nil}

      {:error, :invalid_request} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_unlinked_invoice(mode, invoice_id) do
    transaction(fn ->
      _ =
        Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtext($1))",
          ["stripe:" <> invoice_id],
          @unlogged
        )

      with {:ok, invoice} <- fetch_invoice(invoice_id),
           gym_id when is_binary(gym_id) <-
             customer_gym(mode, invoice.customer) || {:ignore, :unknown_customer} do
        record_invoice!(invoice, %{gym_id: gym_id, id: nil}, mode, Clock.utc_now())
        {:ok, :invoice_recorded}
      end
    end)
  end

  defp record_invoice!(invoice, subscription, mode, now) do
    payment_status = payment_status(invoice)
    previous = Repo.get_by(Invoice, [mode: mode, stripe_invoice_id: invoice.id], @unlogged)

    attrs = %{
      mode: mode,
      gym_id: subscription.gym_id,
      subscription_id: subscription.id,
      stripe_invoice_id: invoice.id,
      stripe_subscription_id: invoice.subscription,
      number: invoice.number,
      status: invoice.status,
      payment_status: payment_status,
      currency: invoice.currency,
      amount_due: invoice.amount_due,
      amount_paid: invoice.amount_paid,
      amount_remaining: invoice.amount_remaining,
      total: invoice.total,
      billing_reason: invoice.billing_reason,
      period_start: invoice.period_start,
      period_end: invoice.period_end,
      hosted_invoice_url: invoice.hosted_invoice_url,
      invoice_pdf: invoice.invoice_pdf,
      paid_at: invoice.paid_at,
      provider_created_at: invoice.created || now,
      attempt_count: invoice.attempt_count,
      next_payment_attempt_at: invoice.next_payment_attempt,
      synced_at: now
    }

    recorded =
      case previous do
        nil -> Repo.insert!(struct(Invoice, attrs), @unlogged)
        %Invoice{} = row -> update!(row, Map.drop(attrs, [:mode, :gym_id, :stripe_invoice_id]))
      end

    if payment_status == :requires_payment_method and
         (previous == nil or previous.payment_status != :requires_payment_method) and
         subscription.id do
      Subscriptions.audit_billing!(subscription, :saas_payment_failed, recorded.id, now)
    end

    recorded
  end

  # The state of the invoice's last payment attempt, read from its
  # PaymentIntent (an open invoice may need customer action or a new
  # payment method). Never card details.
  defp payment_status(%{status: :paid}), do: :succeeded
  defp payment_status(%{status: status}) when status in [:draft, :void, :uncollectible], do: nil

  defp payment_status(%{status: :open, id: id}) do
    with {:ok, %{data: payments}} <-
           Client.get("/v1/invoice_payments", %{invoice: id}, :invoice_payments),
         %{payment_intent: pi} when is_binary(pi) <-
           Enum.find(payments, & &1.is_default) || List.first(payments),
         {:ok, %{status: status}} <-
           Client.get("/v1/payment_intents/#{Client.id!(pi, "pi")}", %{}, :payment_intent) do
      case status do
        "requires_action" -> :requires_action
        "requires_confirmation" -> :requires_action
        "requires_payment_method" -> :requires_payment_method
        "processing" -> :processing
        "succeeded" -> :succeeded
        "canceled" -> :canceled
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  ## Refunds and disputes

  defp apply_refund(mode, %Invoice{} = invoice, refund) do
    invoice = lock_invoice!(invoice)
    now = Clock.utc_now()

    if refund.currency != invoice.currency do
      {:ignore, :refund_currency_mismatch}
    else
      existing =
        Repo.get_by(Refund, [mode: mode, stripe_refund_id: refund.id], @unlogged) ||
          operator_request(invoice, refund)

      row =
        case existing do
          nil ->
            Repo.insert!(
              %Refund{
                mode: mode,
                gym_id: invoice.gym_id,
                invoice_id: invoice.id,
                stripe_refund_id: refund.id,
                origin: :provider,
                status: refund.status,
                amount_minor: refund.amount_minor,
                currency: refund.currency,
                reason: refund.reason,
                synced_at: now
              },
              @unlogged
            )

          %Refund{} = row ->
            update!(row, stripe_refund_id: refund.id, status: refund.status, synced_at: now)
        end

      refunded =
        Repo.one(
          from(r in Refund,
            where: r.invoice_id == ^invoice.id and r.status == :succeeded,
            select: type(coalesce(sum(r.amount_minor), 0), :integer)
          ),
          @unlogged
        )

      update!(invoice, amount_refunded: refunded)

      if row.status == :succeeded and (existing == nil or existing.status != :succeeded),
        do: audit_record!(invoice, :saas_refund_recorded, row.id, now)

      {:ok, :refund_recorded}
    end
  end

  # SimpleFit's own request for this refund (created with our metadata on
  # this very invoice's payment).
  defp operator_request(invoice, refund) do
    with id when is_binary(id) <- refund.simplefit_refund_id,
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      Repo.one(
        from(r in Refund,
          where:
            r.id == ^uuid and r.invoice_id == ^invoice.id and r.origin == :operator and
              is_nil(r.stripe_refund_id) and r.amount_minor == ^refund.amount_minor
        ),
        @unlogged
      )
    else
      _ -> nil
    end
  end

  defp apply_dispute(mode, %Invoice{} = invoice, dispute) do
    invoice = lock_invoice!(invoice)
    now = Clock.utc_now()

    case Repo.get_by(Dispute, [mode: mode, stripe_dispute_id: dispute.id], @unlogged) do
      nil ->
        row =
          Repo.insert!(
            %Dispute{
              mode: mode,
              gym_id: invoice.gym_id,
              invoice_id: invoice.id,
              stripe_dispute_id: dispute.id,
              status: dispute.status,
              reason: dispute.reason,
              amount_minor: dispute.amount_minor,
              currency: dispute.currency,
              synced_at: now
            },
            @unlogged
          )

        update!(invoice, disputed: true)
        audit_record!(invoice, :saas_dispute_recorded, row.id, now)

      %Dispute{} = row ->
        update!(row, status: dispute.status, reason: dispute.reason, synced_at: now)
    end

    {:ok, :dispute_recorded}
  end

  defp audit_record!(%Invoice{} = invoice, event, record_id, now) do
    Gyms.record_commerce_event!(
      %{
        gym_id: invoice.gym_id,
        actor_user_id: nil,
        event_type: event,
        saas_subscription_id: invoice.subscription_id,
        billing_record_id: record_id
      },
      now
    )
  end

  # The gym's invoice a PaymentIntent paid (recorded first if new).
  defp invoice_of(_mode, nil), do: {:ignore, :no_payment_intent}

  defp invoice_of(mode, payment_intent) do
    with {:ok, payments} <- invoice_payments_of(payment_intent),
         %{invoice: invoice_id} when is_binary(invoice_id) <-
           List.first(payments) || {:ignore, :no_invoice} do
      case recorded_invoice(mode, invoice_id) do
        %Invoice{} = invoice -> {:ok, invoice}
        nil -> record_then_get(mode, invoice_id)
      end
    end
  end

  defp record_then_get(mode, invoice_id) do
    with {:ok, _} <- sync_invoice(invoice_id) do
      case recorded_invoice(mode, invoice_id) do
        %Invoice{} = invoice -> {:ok, invoice}
        nil -> {:ignore, :unknown_invoice}
      end
    end
  end

  defp recorded_invoice(mode, invoice_id),
    do: Repo.get_by(Invoice, [mode: mode, stripe_invoice_id: invoice_id], @unlogged)

  defp invoice_payments_of(payment_intent) do
    with {:ok, %{data: payments}} <-
           Client.get(
             "/v1/invoice_payments",
             %{
               payment: %{
                 type: "payment_intent",
                 payment_intent: Client.id!(payment_intent, "pi")
               }
             },
             :invoice_payments
           ) do
      {:ok, payments}
    end
  end

  # The gym row first (shared), as every gym write: see `Subscriptions.lock_for_provider/1`.
  defp lock_invoice!(invoice) do
    :ok = Gyms.lock_gym_shared(invoice.gym_id)
    Repo.one!(from(i in Invoice, where: i.id == ^invoice.id, lock: "FOR UPDATE"), @unlogged)
  end

  ## Lookups

  defp route_by_customer(mode, customer_id, invoice_ids) do
    with gym_id when is_binary(gym_id) <-
           customer_gym(mode, customer_id) || {:ignore, :unknown_customer},
         %Checkout{subscription_id: id} <-
           Repo.one(
             from(c in Checkout,
               join: s in GymSubscription,
               on: s.id == c.subscription_id,
               where:
                 c.gym_id == ^gym_id and c.mode == ^mode and c.status in [:open, :completed] and
                   s.status == :pending_activation,
               order_by: [desc: c.inserted_at],
               limit: 1
             ),
             @unlogged
           ) || {:ignore, :unmapped_subscription} do
      reconcile_subscription(id, invoice_ids)
    end
  end

  defp customer_gym(_mode, nil), do: nil

  defp customer_gym(mode, customer_id),
    do:
      Repo.one(
        from(c in Customer,
          where: c.mode == ^mode and c.stripe_customer_id == ^customer_id,
          select: c.gym_id
        ),
        @unlogged
      )

  defp link_by_stripe_id(mode, id),
    do: Repo.get_by(SubscriptionLink, [mode: mode, stripe_subscription_id: id], @unlogged)

  defp mapping_for(subscription, mode) do
    price = Repo.get!(PriceVersion, subscription.price_version_id, @unlogged)

    case Repo.get_by(PriceMapping, [mode: mode, price_version_id: price.id], @unlogged) do
      %PriceMapping{} = mapping -> {:ok, mapping, price}
      nil -> {:ignore, :price_not_mapped}
    end
  end

  defp fetch_subscription(id),
    do: Client.get("/v1/subscriptions/#{Client.id!(id, "sub")}", %{}, :subscription)

  defp fetch_invoice(id), do: Client.get("/v1/invoices/#{Client.id!(id, "in")}", %{}, :invoice)

  ## Helpers

  defp update!(struct, changes),
    do: struct |> Ecto.Changeset.change(changes) |> Repo.update!(@unlogged)

  # Runs `fun` in a transaction; `{:ok, _}` commits, `{:ignore, _}` and
  # `{:error, _}` roll back and are returned as they are.
  defp transaction(fun) do
    case Repo.transaction(fn -> commit_or_rollback(fun.()) end, @unlogged) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp commit_or_rollback({:ok, _} = ok), do: ok
  defp commit_or_rollback(other), do: Repo.rollback(other)

  defp combine(results) do
    Enum.find(results, &match?({:error, _}, &1)) || Enum.find(results, &match?({:ok, _}, &1)) ||
      List.first(results)
  end
end
