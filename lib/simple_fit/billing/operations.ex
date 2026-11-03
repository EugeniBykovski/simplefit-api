defmodule SimpleFit.Billing.Operations do
  @moduledoc """
  Operator actions on the Stripe integration (SF-102), run through
  `mix billing.stripe`. None is reachable over HTTP; each names the operator
  and is audited in `billing_audit_events`.

  * `map_price/2` - creates the Stripe Product and Price of an SF-101 fixed
    price version in the configured mode (idempotent per price version and
    mode) and records the mapping after checking Stripe answered the same
    amount, currency and interval. Test mode accepts any fixed price
    (including drafts and provisional prices, for sandbox testing); **live
    mode only a published, non-provisional version** (and live mode itself
    needs the release approval).
  * `setup_portal/1` - creates the Customer Portal configuration SimpleFit
    supports (payment method update, invoice history, billing details; no
    plan change, no cancellation) and answers its id for
    `STRIPE_PORTAL_CONFIGURATION_ID`.
  * `refund/4` - a full refund of a paid SaaS invoice under an approval
    reference: one per invoice (the invoice row is locked and a partial
    unique index refuses a second), requested at Stripe with an idempotency
    key, its outcome reconciled. Partial refunds are not approved and are
    refused. A refund never revokes an entitlement by itself.
  * `link_connected_account/3`, `sync_connected_account/1` - the Stripe
    Connect foundation (see `SimpleFit.Billing.Connect`).
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.{Clock, Gyms, Repo}

  alias SimpleFit.Billing.{
    AuditEvent,
    Catalog,
    Connect,
    PlanVersion,
    PriceVersion,
    Reconciliation
  }

  alias SimpleFit.Billing.Stripe.{Client, Config, ConnectedAccount, Invoice, PriceMapping, Refund}

  @unlogged [log: false]

  @type error :: :not_found | {:conflict, map()} | SimpleFit.Provider.error()

  ## Prices

  @doc "Maps an SF-101 price version to a Stripe Price (see the moduledoc)."
  @spec map_price(term(), String.t()) :: {:ok, PriceMapping.t()} | {:error, error()}
  def map_price(price_version_id, operator) when is_binary(operator) and operator != "" do
    with {:ok, config} <- Config.fetch(),
         {:ok, price, version} <- price_version(price_version_id),
         :ok <- sellable(price, version, config.mode) do
      case Repo.get_by(PriceMapping, [mode: config.mode, price_version_id: price.id], @unlogged) do
        %PriceMapping{} = mapping -> {:ok, mapping}
        nil -> create_mapping(price, version, operator, config.mode)
      end
    end
  end

  defp price_version(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %PriceVersion{} = price <- Repo.get(PriceVersion, uuid, @unlogged),
         {:ok, version} <- Catalog.get_version(price.plan_version_id) do
      {:ok, price, version}
    else
      _ -> {:error, :not_found}
    end
  end

  defp sellable(%PriceVersion{pricing: :quote_required}, _version, _mode),
    do: {:error, {:conflict, %{saas_price_version: "quote_required"}}}

  defp sellable(%PriceVersion{amount_minor: amount}, _version, _mode) when amount <= 0,
    do: {:error, {:conflict, %{saas_price_version: "free"}}}

  defp sellable(_price, %PlanVersion{status: status}, :live) when status != :published,
    do: {:error, {:conflict, %{saas_plan_version: Atom.to_string(status)}}}

  defp sellable(_price, %PlanVersion{price_source: :provisional}, :live),
    do: {:error, {:conflict, %{saas_plan_version: "provisional"}}}

  defp sellable(_price, _version, _mode), do: :ok

  defp create_mapping(price, version, operator, mode) do
    with {:ok, product} <-
           Client.post(
             "/v1/products",
             %{
               name: "SimpleFit #{version.name}",
               metadata: %{simplefit_plan_version_id: version.id, simplefit_mode: mode}
             },
             :product,
             idempotency_key: "simplefit-product-#{mode}-#{price.id}"
           ),
         {:ok, stripe_price} <-
           Client.post(
             "/v1/prices",
             %{
               product: product.id,
               currency: String.downcase(price.currency),
               unit_amount: price.amount_minor,
               recurring: %{interval: price.interval, interval_count: 1},
               metadata: %{simplefit_price_version_id: price.id, simplefit_mode: mode}
             },
             :price,
             idempotency_key: "simplefit-price-#{mode}-#{price.id}"
           ),
         :ok <- same_price(stripe_price, price) do
      Repo.transaction(
        fn ->
          mapping =
            Repo.insert!(
              %PriceMapping{
                mode: mode,
                price_version_id: price.id,
                stripe_product_id: product.id,
                stripe_price_id: stripe_price.id,
                currency: price.currency,
                amount_minor: price.amount_minor,
                interval: price.interval,
                mapped_by: operator
              },
              @unlogged
            )

          audit!(:stripe_price_mapped, operator, %{
            plan_version_id: version.id,
            plan_id: version.plan_id,
            billing_record_id: mapping.id
          })

          mapping
        end,
        @unlogged
      )
    end
  end

  defp same_price(stripe_price, price) do
    if stripe_price.amount_minor == price.amount_minor and stripe_price.currency == price.currency and
         stripe_price.interval == price.interval and stripe_price.interval_count == 1,
       do: :ok,
       else: {:error, {:conflict, %{stripe_price: "mismatch"}}}
  end

  ## Portal

  @doc "Creates SimpleFit's Customer Portal configuration (see the moduledoc)."
  @spec setup_portal(String.t()) :: {:ok, String.t()} | {:error, error()}
  def setup_portal(operator) when is_binary(operator) and operator != "" do
    with {:ok, config} <- Config.fetch(),
         {:ok, %{id: id}} <-
           Client.post(
             "/v1/billing_portal/configurations",
             %{
               name: "SimpleFit gym billing",
               features: %{
                 payment_method_update: %{enabled: true},
                 invoice_history: %{enabled: true},
                 customer_update: %{enabled: true, allowed_updates: ["address", "name", "tax_id"]},
                 subscription_cancel: %{enabled: false},
                 subscription_update: %{enabled: false}
               },
               metadata: %{simplefit_mode: config.mode, configured_by: operator}
             },
             :portal_configuration
           ) do
      {:ok, id}
    end
  end

  ## Refunds

  @doc "A full refund of a paid SaaS invoice (see the moduledoc). `opts`: `:amount` (refused unless the full amount)."
  @spec refund(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Refund.t()} | {:error, error()}
  def refund(stripe_invoice_id, operator, approval, opts \\ [])
      when is_binary(operator) and operator != "" and is_binary(approval) and approval != "" do
    with {:ok, config} <- Config.fetch(),
         {:ok, request} <-
           request_refund(config.mode, stripe_invoice_id, operator, approval, opts),
         {:ok, payment_intent} <- paid_intent(request.invoice) do
      request.refund
      |> refund_at_stripe(payment_intent, opts)
      |> refund_outcome(request.refund)
    end
  end

  # The request's own idempotency key: a retry after a lost answer returns
  # the refund Stripe already made, never a second one.
  defp refund_at_stripe(refund, payment_intent, opts) do
    Client.post(
      "/v1/refunds",
      %{
        payment_intent: payment_intent,
        amount: refund.amount_minor,
        reason: opts[:reason],
        metadata: %{simplefit_refund_id: refund.id}
      },
      :refund,
      idempotency_key: "simplefit-refund-" <> refund.idempotency_key
    )
  end

  defp refund_outcome({:ok, stripe_refund}, refund) do
    _ = Reconciliation.sync_refund(stripe_refund.id)
    {:ok, Repo.reload!(refund, @unlogged)}
  end

  defp refund_outcome({:error, reason}, refund) do
    if not SimpleFit.Provider.retryable?(reason),
      do: refund |> Ecto.Changeset.change(status: :failed) |> Repo.update!(@unlogged)

    {:error, reason}
  end

  defp request_refund(mode, stripe_invoice_id, operator, approval, opts) do
    Repo.transaction(
      fn ->
        invoice = lock_invoice(mode, stripe_invoice_id) || Repo.rollback(:not_found)
        amount = opts[:amount] || invoice.amount_paid

        case refundable(invoice, amount) do
          {:retry, refund} ->
            %{invoice: invoice, refund: refund}

          :ok ->
            %{invoice: invoice, refund: insert_refund!(invoice, amount, operator, approval, opts)}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      @unlogged
    )
  end

  # The gym row first (shared), as every gym write, then the invoice.
  defp lock_invoice(mode, stripe_invoice_id) do
    query =
      from(i in Invoice, where: i.mode == ^mode and i.stripe_invoice_id == ^stripe_invoice_id)

    case Repo.one(from(i in query, select: i.gym_id), @unlogged) do
      nil ->
        nil

      gym_id ->
        :ok = Gyms.lock_gym_shared(gym_id)
        Repo.one!(from(i in query, lock: "FOR UPDATE"), @unlogged)
    end
  end

  # Full refunds of paid invoices only, once; a request whose answer was lost
  # (still `requested`, no Stripe id) is retried as it is.
  defp refundable(%Invoice{status: :paid} = invoice, amount) do
    cond do
      amount != invoice.amount_paid ->
        {:error, {:conflict, %{refund: "partial_not_approved"}}}

      refund = unanswered_request(invoice) ->
        {:retry, refund}

      invoice.amount_refunded > 0 or open_refund?(invoice) ->
        {:error, {:conflict, %{refund: "exists"}}}

      true ->
        :ok
    end
  end

  defp refundable(%Invoice{status: status}, _amount),
    do: {:error, {:conflict, %{invoice: Atom.to_string(status)}}}

  defp unanswered_request(invoice),
    do:
      Repo.one(
        from(r in Refund,
          where:
            r.invoice_id == ^invoice.id and r.origin == :operator and r.status == :requested and
              is_nil(r.stripe_refund_id)
        ),
        @unlogged
      )

  defp insert_refund!(invoice, amount, operator, approval, opts) do
    refund =
      Repo.insert!(
        %Refund{
          mode: invoice.mode,
          gym_id: invoice.gym_id,
          invoice_id: invoice.id,
          idempotency_key: Ecto.UUID.generate(),
          origin: :operator,
          status: :requested,
          amount_minor: amount,
          currency: invoice.currency,
          reason: opts[:reason],
          requested_by: operator,
          approval_reference: approval
        },
        @unlogged
      )

    audit!(:stripe_refund_requested, operator, %{
      gym_id: invoice.gym_id,
      approval_reference: approval,
      billing_record_id: refund.id
    })

    refund
  end

  defp open_refund?(invoice),
    do:
      Repo.exists?(
        from(r in Refund,
          where:
            r.invoice_id == ^invoice.id and
              r.status in [:requested, :pending, :requires_action, :succeeded]
        )
      )

  defp paid_intent(invoice) do
    with {:ok, %{data: payments}} <-
           Client.get(
             "/v1/invoice_payments",
             %{invoice: invoice.stripe_invoice_id, status: "paid"},
             :invoice_payments
           ),
         %{payment_intent: pi} when is_binary(pi) <-
           Enum.find(payments, & &1.is_default) || List.first(payments) do
      {:ok, pi}
    else
      {:error, _} = error -> error
      _ -> {:error, {:conflict, %{invoice: "no_payment"}}}
    end
  end

  ## Connect

  @doc "See `SimpleFit.Billing.Connect.link/3`."
  @spec link_connected_account(term(), String.t(), String.t()) ::
          {:ok, ConnectedAccount.t()} | {:error, error()}
  def link_connected_account(gym_id, account_id, operator) do
    Repo.transaction(
      fn ->
        case Connect.link(gym_id, account_id, operator) do
          {:ok, account} ->
            audit!(:stripe_connected_account_linked, operator, %{
              gym_id: account.gym_id,
              billing_record_id: account.id
            })

            account

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      @unlogged
    )
  end

  @doc "See `SimpleFit.Billing.Connect.sync/1`."
  @spec sync_connected_account(String.t()) :: {:ok, ConnectedAccount.t()} | {:error, error()}
  defdelegate sync_connected_account(account_id), to: Connect, as: :sync

  defp audit!(event, operator, attrs) do
    Repo.insert!(
      struct(
        AuditEvent,
        Map.merge(attrs, %{event_type: event, actor: operator, occurred_at: Clock.utc_now()})
      ),
      @unlogged
    )
  end
end
