defmodule SimpleFit.Billing.Stripe.Objects do
  @moduledoc """
  Decodes Stripe API objects (API version `2026-10-28.endive`) into the
  plain maps SimpleFit reads (SF-102). Only the fields reconciliation needs
  are kept: identifiers, statuses, amounts in minor units, ISO currencies
  (upper case), periods and Stripe-hosted URLs. No card, bank, email,
  address or tax data is kept. A missing required field is `:error` (an
  unexpected answer).

  Version notes: a Subscription's billing period lives on its items
  (`items.data[].current_period_*`) and an Invoice names its subscription
  under `parent.subscription_details.subscription`; an invoice's payments
  are `invoice_payment` objects.
  """

  @type decoded :: {:ok, map()} | :error

  @doc "A Customer (`cus_`)."
  @spec customer(map()) :: decoded()
  def customer(%{"object" => "customer", "id" => "cus_" <> _ = id} = c),
    do: {:ok, %{id: id, deleted: c["deleted"] == true}}

  def customer(_), do: :error

  @doc "A Product (`prod_`)."
  @spec product(map()) :: decoded()
  def product(%{"object" => "product", "id" => "prod_" <> _ = id} = p),
    do: {:ok, %{id: id, active: p["active"] == true}}

  def product(_), do: :error

  @doc "A recurring Price (`price_`)."
  @spec price(map()) :: decoded()
  def price(%{"object" => "price", "id" => "price_" <> _ = id, "currency" => currency} = p)
      when is_binary(currency) do
    with interval when interval in ["month", "year"] <- get_in(p, ["recurring", "interval"]),
         amount when is_integer(amount) <- p["unit_amount"] do
      {:ok,
       %{
         id: id,
         active: p["active"] == true,
         currency: String.upcase(currency),
         amount_minor: amount,
         interval: if(interval == "month", do: :month, else: :year),
         interval_count: get_in(p, ["recurring", "interval_count"]) || 1,
         product: ref(p["product"])
       }}
    else
      _ -> :error
    end
  end

  def price(_), do: :error

  @doc "A Checkout Session (`cs_`)."
  @spec checkout_session(map()) :: decoded()
  def checkout_session(%{"object" => "checkout.session", "id" => "cs_" <> _ = id} = s) do
    with {:ok, status} <- enum(s["status"], ~w(open complete expired)a) do
      {:ok,
       %{
         id: id,
         status: status,
         mode: s["mode"],
         payment_status: s["payment_status"],
         customer: ref(s["customer"]),
         subscription: ref(s["subscription"]),
         invoice: ref(s["invoice"]),
         client_reference_id: s["client_reference_id"],
         url: s["url"],
         expires_at: time(s["expires_at"])
       }}
    end
  end

  def checkout_session(_), do: :error

  @doc "A Subscription (`sub_`) with one item (SimpleFit sells one price per subscription)."
  @spec subscription(map()) :: decoded()
  def subscription(%{"object" => "subscription", "id" => "sub_" <> _ = id} = s) do
    with {:ok, status} <-
           enum(s["status"], ~w(incomplete incomplete_expired trialing active past_due canceled
                                unpaid paused)a),
         [item] <- get_in(s, ["items", "data"]) || :error do
      {:ok,
       %{
         id: id,
         status: status,
         customer: ref(s["customer"]),
         cancel_at_period_end: s["cancel_at_period_end"] == true,
         cancel_at: time(s["cancel_at"]),
         canceled_at: time(s["canceled_at"]),
         ended_at: time(s["ended_at"]),
         cancellation_reason: get_in(s, ["cancellation_details", "reason"]),
         latest_invoice: ref(s["latest_invoice"]),
         price: ref(item["price"]),
         quantity: item["quantity"] || 1,
         current_period_start: time(item["current_period_start"]),
         current_period_end: time(item["current_period_end"])
       }}
    else
      _ -> :error
    end
  end

  def subscription(_), do: :error

  @doc "An Invoice (`in_`) with its subscription line's period and price."
  @spec invoice(map()) :: decoded()
  def invoice(%{"object" => "invoice", "id" => "in_" <> _ = id, "currency" => currency} = i)
      when is_binary(currency) do
    with {:ok, status} <- enum(i["status"], ~w(draft open paid uncollectible void)a),
         amounts when is_map(amounts) <- amounts(i) do
      line = subscription_line(i)

      {:ok,
       Map.merge(amounts, %{
         id: id,
         status: status,
         customer: ref(i["customer"]),
         subscription: ref(get_in(i, ["parent", "subscription_details", "subscription"])),
         currency: String.upcase(currency),
         number: i["number"],
         billing_reason: i["billing_reason"],
         hosted_invoice_url: i["hosted_invoice_url"],
         invoice_pdf: i["invoice_pdf"],
         attempt_count: i["attempt_count"] || 0,
         next_payment_attempt: time(i["next_payment_attempt"]),
         paid_at: time(get_in(i, ["status_transitions", "paid_at"])),
         created: time(i["created"]),
         period_start: line && time(get_in(line, ["period", "start"])),
         period_end: line && time(get_in(line, ["period", "end"])),
         price: line && line_price(line)
       })}
    else
      _ -> :error
    end
  end

  def invoice(_), do: :error

  @doc "A list of objects decoded by `decoder`."
  @spec list(map(), atom()) :: decoded()
  def list(%{"object" => "list", "data" => data}, decoder) when is_list(data) do
    data
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case apply(__MODULE__, decoder, [item]) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, %{data: Enum.reverse(items)}}
      :error -> :error
    end
  end

  def list(_, _), do: :error

  @doc "A list of invoice payments."
  @spec invoice_payments(map()) :: decoded()
  def invoice_payments(body), do: list(body, :invoice_payment)

  @doc "A list of refunds."
  @spec refunds(map()) :: decoded()
  def refunds(body), do: list(body, :refund)

  @doc "An invoice payment (`inpay_`): which PaymentIntent paid (or tried to pay) which invoice."
  @spec invoice_payment(map()) :: decoded()
  def invoice_payment(%{"object" => "invoice_payment", "id" => id} = p) when is_binary(id) do
    {:ok,
     %{
       id: id,
       invoice: ref(p["invoice"]),
       status: p["status"],
       is_default: p["is_default"] == true,
       payment_intent: ref(get_in(p, ["payment", "payment_intent"]))
     }}
  end

  def invoice_payment(_), do: :error

  @doc "A PaymentIntent's status (no payment method details)."
  @spec payment_intent(map()) :: decoded()
  def payment_intent(%{"object" => "payment_intent", "id" => "pi_" <> _ = id, "status" => status})
      when is_binary(status),
      do: {:ok, %{id: id, status: status}}

  def payment_intent(_), do: :error

  @doc "A Refund (`re_`)."
  @spec refund(map()) :: decoded()
  def refund(%{"object" => "refund", "id" => id, "amount" => amount, "currency" => currency} = r)
      when is_binary(id) and is_integer(amount) and is_binary(currency) do
    with {:ok, status} <-
           enum(r["status"], ~w(pending requires_action succeeded failed canceled)a) do
      {:ok,
       %{
         id: id,
         status: status,
         amount_minor: amount,
         currency: String.upcase(currency),
         payment_intent: ref(r["payment_intent"]),
         charge: ref(r["charge"]),
         reason: r["reason"],
         simplefit_refund_id: get_in(r, ["metadata", "simplefit_refund_id"])
       }}
    end
  end

  def refund(_), do: :error

  @doc "A Charge's PaymentIntent (for `charge.*` events)."
  @spec charge(map()) :: decoded()
  def charge(%{"object" => "charge", "id" => "ch_" <> _ = id} = c),
    do: {:ok, %{id: id, payment_intent: ref(c["payment_intent"])}}

  def charge(_), do: :error

  @doc "A Dispute (`dp_`/`du_`)."
  @spec dispute(map()) :: decoded()
  def dispute(
        %{
          "object" => "dispute",
          "id" => id,
          "amount" => amount,
          "currency" => currency,
          "status" => status
        } = d
      )
      when is_binary(id) and is_integer(amount) and is_binary(currency) and is_binary(status) do
    {:ok,
     %{
       id: id,
       status: status,
       reason: d["reason"],
       amount_minor: amount,
       currency: String.upcase(currency),
       payment_intent: ref(d["payment_intent"]),
       charge: ref(d["charge"])
     }}
  end

  def dispute(_), do: :error

  @doc "A billing portal session's short-lived URL."
  @spec portal_session(map()) :: decoded()
  def portal_session(%{"object" => "billing_portal.session", "url" => url}) when is_binary(url),
    do: {:ok, %{url: url}}

  def portal_session(_), do: :error

  @doc "A billing portal configuration (`bpc_`)."
  @spec portal_configuration(map()) :: decoded()
  def portal_configuration(%{
        "object" => "billing_portal.configuration",
        "id" => "bpc_" <> _ = id
      }),
      do: {:ok, %{id: id}}

  def portal_configuration(_), do: :error

  @doc "The Balance: read only for the key's mode, never its amounts (SF-138)."
  @spec balance(map()) :: decoded()
  def balance(%{"object" => "balance", "livemode" => livemode}) when is_boolean(livemode),
    do: {:ok, %{livemode: livemode}}

  def balance(_), do: :error

  @doc "A Connect account (`acct_`): capability summary only, no KYC data."
  @spec account(map()) :: decoded()
  def account(%{"object" => "account", "id" => "acct_" <> _ = id} = a) do
    {:ok,
     %{
       id: id,
       charges_enabled: a["charges_enabled"] == true,
       payouts_enabled: a["payouts_enabled"] == true,
       details_submitted: a["details_submitted"] == true,
       requirements_due_count: length(get_in(a, ["requirements", "currently_due"]) || []),
       disabled_reason: get_in(a, ["requirements", "disabled_reason"])
     }}
  end

  def account(_), do: :error

  ## Helpers

  defp amounts(i) do
    keys = ~w(amount_due amount_paid amount_remaining total)

    if Enum.all?(keys, &is_integer(i[&1])),
      do: %{
        amount_due: i["amount_due"],
        amount_paid: i["amount_paid"],
        amount_remaining: i["amount_remaining"],
        total: i["total"]
      },
      else: :error
  end

  # The line billing the subscription item (its period is the paid period).
  defp subscription_line(i) do
    lines = get_in(i, ["lines", "data"]) || []

    Enum.find(lines, &(get_in(&1, ["parent", "type"]) == "subscription_item_details")) ||
      List.first(lines)
  end

  defp line_price(line),
    do: ref(get_in(line, ["pricing", "price_details", "price"]))

  defp enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp enum(_value, _allowed), do: :error

  # An expandable reference: the id, whether expanded or not.
  defp ref(%{"id" => id}) when is_binary(id), do: id
  defp ref(id) when is_binary(id), do: id
  defp ref(_), do: nil

  defp time(seconds) when is_integer(seconds),
    do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)

  defp time(_), do: nil
end
