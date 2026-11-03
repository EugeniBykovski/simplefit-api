defmodule SimpleFit.StripeFake do
  @moduledoc """
  A deterministic, in-process fake of the Stripe API endpoints SimpleFit
  calls (SF-102), served through `Req.Test` (`config/test.exs`). It is a
  test double only: compiled in `test/support`, never configured outside
  tests, and nothing it answers is evidence of a real payment.

  It mirrors the documented shapes of API version `2026-10-28.endive`
  (periods on subscription items, `invoice.parent.subscription_details`,
  `invoice_payment` objects), enforces `Idempotency-Key` semantics (the same
  key returns the first answer; with other parameters it is a 400), checks
  the `Stripe-Version` and bearer key on every request, and records every
  request for assertions. Test helpers drive provider-side events
  (`complete_checkout/2`, `renew/2`, `fail_renewal/1`, ...) and faults
  (`fail_next/3`: a 5xx, a timeout, or a lost answer after the effect).

  Use `start!/0` in a test (or `setup`); processes started by the test
  (Tasks, `perform_job/2`) reach the same state through `$callers`.
  """

  use Agent

  alias Plug.Conn

  @key "sk_test_notarealkey"

  ## Setup

  @doc "Starts a fresh fake for the calling test and stubs `Req.Test` with it."
  def start! do
    {:ok, agent} = Agent.start_link(fn -> initial() end)
    Process.put(__MODULE__, agent)
    Req.Test.stub(__MODULE__, fn conn -> handle(agent, conn) end)
    agent
  end

  # The test's fake, also from processes it started (Tasks, through `$callers`).
  defp agent do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, __MODULE__)
        nil -> nil
      end
    end) || raise("StripeFake.start!/0 was not called")
  end

  defp initial do
    %{
      seq: 0,
      objects: %{},
      idempotency: %{},
      requests: [],
      faults: [],
      now: System.os_time(:second)
    }
  end

  ## Inspection

  @doc "Every request so far, oldest first: `{method, path, params}`."
  def requests, do: Agent.get(agent(), &Enum.reverse(&1.requests))

  @doc "How many requests matched `method` and `path` (a string or a regex)."
  def count(method, path) do
    Enum.count(requests(), fn {m, p, _} -> m == method and match_path?(p, path) end)
  end

  @doc "A stored object by id."
  def get(id), do: Agent.get(agent(), &Map.get(&1.objects, id))

  @doc "Replaces fields of a stored object (simulates a change at Stripe)."
  def put(id, fields),
    do: Agent.update(agent(), &update_in(&1, [:objects, id], fn o -> Map.merge(o, fields) end))

  @doc "Stores an arbitrary object (for foreign or other-mode objects)."
  def insert(object), do: Agent.update(agent(), &put_in(&1, [:objects, object["id"]], object))

  @doc "Removes an object (it then answers 404, as another account's object would)."
  def forget(id),
    do: Agent.update(agent(), &update_in(&1, [:objects], fn o -> Map.delete(o, id) end))

  @doc """
  The next request matching `method` and `path` fails: `:server_error`
  (500, nothing happened), `:timeout` (nothing happened) or `:lost` (the
  effect happened, the answer is lost as a timeout).
  """
  def fail_next(method, path, fault),
    do: Agent.update(agent(), &%{&1 | faults: &1.faults ++ [{method, path, fault}]})

  ## Provider-side scenarios

  @doc """
  The customer completes the hosted checkout `session_id`. `outcome`:
  `:paid` (default; subscription `active`, first invoice `paid`),
  `:action_required` (SCA: `incomplete`, invoice `open`, PaymentIntent
  `requires_action`), `:failed` (`incomplete`, `requires_payment_method`).
  Options: `amount` (the invoice total, default the price's amount).
  Returns `%{subscription: id, invoice: id, ...}`, or `:not_open` when the
  session is no longer open (expired sessions cannot be paid).
  """
  def complete_checkout(session_id, outcome \\ :paid, opts \\ []) do
    Agent.get_and_update(agent(), fn state ->
      case state.objects[session_id] do
        %{"status" => "open"} = session -> do_complete(state, session, outcome, opts)
        _ -> {:not_open, state}
      end
    end)
  end

  defp do_complete(state, session, outcome, opts) do
    (fn ->
       price = state.objects[session["_price"]]
       now = state.now
       period_end = now + period(price)
       {sub_id, state} = next_id(state, "sub")
       {invoice_id, state} = next_id(state, "in")
       {pi_id, state} = next_id(state, "pi")
       {ch_id, state} = next_id(state, "ch")
       {inpay_id, state} = next_id(state, "inpay")
       amount = Keyword.get(opts, :amount, price["unit_amount"])

       {sub_status, invoice_status, pi_status} =
         case outcome do
           :paid -> {"active", "paid", "succeeded"}
           :action_required -> {"incomplete", "open", "requires_action"}
           :failed -> {"incomplete", "open", "requires_payment_method"}
         end

       subscription =
         subscription(sub_id, session["customer"], price, sub_status, now, period_end, invoice_id)

       invoice =
         invoice(%{
           id: invoice_id,
           customer: session["customer"],
           subscription: sub_id,
           price: price,
           amount: amount,
           status: invoice_status,
           from: now,
           to: period_end,
           reason: "subscription_create"
         })

       state =
         state
         |> put_object(subscription)
         |> put_object(invoice)
         |> put_object(payment_intent(pi_id, pi_status, ch_id))
         |> put_object(%{
           "object" => "charge",
           "id" => ch_id,
           "payment_intent" => pi_id,
           "livemode" => false
         })
         |> put_object(
           invoice_payment(
             inpay_id,
             invoice_id,
             pi_id,
             if(invoice_status == "paid", do: "paid", else: "open")
           )
         )
         |> put_object(
           Map.merge(session, %{
             "status" => "complete",
             "subscription" => sub_id,
             "invoice" => invoice_id,
             "payment_status" => if(invoice_status == "paid", do: "paid", else: "unpaid")
           })
         )

       {%{subscription: sub_id, invoice: invoice_id, payment_intent: pi_id, charge: ch_id}, state}
     end).()
  end

  @doc "The customer completes authentication (or a new payment method): the open first invoice is paid."
  def pay_invoice(invoice_id) do
    Agent.update(agent(), fn state ->
      invoice = state.objects[invoice_id]
      sub_id = get_in(invoice, ["parent", "subscription_details", "subscription"])

      inpay =
        Enum.find_value(state.objects, fn {_, o} ->
          (o["object"] == "invoice_payment" and o["invoice"] == invoice_id) && o
        end)

      state
      |> put_object(
        Map.merge(invoice, %{
          "status" => "paid",
          "amount_paid" => invoice["total"],
          "amount_remaining" => 0,
          "status_transitions" => %{"paid_at" => state.now}
        })
      )
      |> put_object(Map.put(inpay, "status", "paid"))
      |> update_object(get_in(inpay, ["payment", "payment_intent"]), %{"status" => "succeeded"})
      |> update_object(sub_id, %{"status" => "active"})
    end)
  end

  @doc "Stripe renews the subscription: the next period is invoiced and paid (`amount` overrides the total)."
  def renew(sub_id, opts \\ []), do: next_invoice(sub_id, "paid", "succeeded", opts)

  @doc "Stripe's renewal attempt fails: the invoice stays open (`requires_payment_method`), the subscription `past_due`."
  def fail_renewal(sub_id), do: next_invoice(sub_id, "open", "requires_payment_method", [])

  defp next_invoice(sub_id, invoice_status, pi_status, opts) do
    Agent.get_and_update(agent(), fn state ->
      sub = state.objects[sub_id]
      [item] = sub["items"]["data"]
      price = state.objects[item["price"]["id"]]
      from = item["current_period_end"]
      to = from + period(price)
      {invoice_id, state} = next_id(state, "in")
      {pi_id, state} = next_id(state, "pi")
      {ch_id, state} = next_id(state, "ch")
      {inpay_id, state} = next_id(state, "inpay")
      amount = Keyword.get(opts, :amount, price["unit_amount"])

      sub =
        if invoice_status == "paid",
          do:
            put_in(sub, ["items", "data"], [
              Map.merge(item, %{"current_period_start" => from, "current_period_end" => to})
            ])
            |> Map.merge(%{"status" => "active", "latest_invoice" => invoice_id}),
          else: Map.merge(sub, %{"status" => "past_due", "latest_invoice" => invoice_id})

      state =
        state
        |> put_object(sub)
        |> put_object(
          invoice(%{
            id: invoice_id,
            customer: sub["customer"],
            subscription: sub_id,
            price: price,
            amount: amount,
            status: invoice_status,
            from: from,
            to: to,
            reason: "subscription_cycle"
          })
        )
        |> put_object(payment_intent(pi_id, pi_status, ch_id))
        |> put_object(%{
          "object" => "charge",
          "id" => ch_id,
          "payment_intent" => pi_id,
          "livemode" => false
        })
        |> put_object(
          invoice_payment(
            inpay_id,
            invoice_id,
            pi_id,
            if(invoice_status == "paid", do: "paid", else: "open")
          )
        )

      {%{invoice: invoice_id, payment_intent: pi_id, charge: ch_id}, state}
    end)
  end

  @doc "Advances the fake's clock (seconds)."
  def advance(seconds), do: Agent.update(agent(), &%{&1 | now: &1.now + seconds})

  @doc "Stripe ends the subscription (`reason`: `cancellation_requested`, `payment_failed`, ...)."
  def end_subscription(sub_id, reason \\ "cancellation_requested") do
    Agent.update(agent(), fn state ->
      update_object(state, sub_id, %{
        "status" => "canceled",
        "canceled_at" => state.now,
        "ended_at" => state.now,
        "cancellation_details" => %{"reason" => reason}
      })
    end)
  end

  @doc "A refund created at Stripe (outside SimpleFit) for `charge_id`/`pi_id`."
  def refund_at_stripe(pi_id, charge_id, amount, currency \\ "pln") do
    Agent.get_and_update(agent(), fn state ->
      {id, state} = next_id(state, "re")
      refund = refund(id, pi_id, charge_id, amount, currency, "succeeded", %{})
      {id, put_object(state, refund)}
    end)
  end

  @doc "A dispute opened at Stripe for a payment."
  def dispute(pi_id, charge_id, amount, currency \\ "pln", status \\ "needs_response") do
    Agent.get_and_update(agent(), fn state ->
      {id, state} = next_id(state, "dp")

      dispute = %{
        "object" => "dispute",
        "id" => id,
        "amount" => amount,
        "currency" => currency,
        "status" => status,
        "reason" => "fraudulent",
        "payment_intent" => pi_id,
        "charge" => charge_id,
        "livemode" => false
      }

      {id, put_object(state, dispute)}
    end)
  end

  @doc "A test-mode connected account."
  def account(id \\ nil, fields \\ %{}) do
    Agent.get_and_update(agent(), fn state ->
      {generated, state} = next_id(state, "acct")
      id = id || generated

      account =
        Map.merge(
          %{
            "object" => "account",
            "id" => id,
            "charges_enabled" => false,
            "payouts_enabled" => false,
            "details_submitted" => false,
            "requirements" => %{
              "currently_due" => ["business_profile.url"],
              "disabled_reason" => "requirements.past_due"
            },
            "livemode" => false
          },
          fields
        )

      {id, put_object(state, account)}
    end)
  end

  @doc "A Stripe event body for `object_id` (snapshot: only ids are read by SimpleFit)."
  def event(type, object_type, object_id, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "evt_#{System.unique_integer([:positive])}"),
      "object" => "event",
      "type" => type,
      "livemode" => Keyword.get(opts, :livemode, false),
      "created" => Keyword.get(opts, :created, System.os_time(:second)),
      "api_version" => "2026-10-28.endive",
      "data" => %{
        "object" =>
          Map.merge(
            %{"id" => object_id, "object" => object_type},
            Keyword.get(opts, :object, %{})
          )
      }
    }
    |> then(fn e -> if acct = opts[:account], do: Map.put(e, "account", acct), else: e end)
  end

  ## Request handling

  defp handle(agent, conn) do
    conn = Conn.fetch_query_params(conn)
    {:ok, body, conn} = Conn.read_body(conn)
    params = Map.merge(conn.query_params, Conn.Query.decode(body))
    method = conn.method
    path = conn.request_path
    key = conn |> Conn.get_req_header("idempotency-key") |> List.first()

    cond do
      Conn.get_req_header(conn, "authorization") != ["Bearer " <> @key] ->
        reply(conn, 401, error("authentication_required"))

      Conn.get_req_header(conn, "stripe-version") != ["2026-10-28.endive"] ->
        reply(conn, 400, error("invalid_version"))

      true ->
        Agent.update(agent, &%{&1 | requests: [{method, path, params} | &1.requests]})

        case take_fault(agent, method, path) do
          :server_error -> reply(conn, 500, error("api_error"))
          :timeout -> Req.Test.transport_error(conn, :timeout)
          fault -> respond(agent, conn, method, path, params, key, fault)
        end
    end
  end

  defp respond(agent, conn, method, path, params, key, fault) do
    {status, response} =
      Agent.get_and_update(agent, &idempotent(&1, method, path, params, key))

    if fault == :lost,
      do: Req.Test.transport_error(conn, :timeout),
      else: reply(conn, status, response)
  end

  # Stripe's idempotency: the same key and parameters return the first
  # answer; the same key with other parameters is a 400.
  defp idempotent(state, method, path, params, key) do
    case key && state.idempotency[key] do
      {^params, ^path, stored} ->
        {stored, state}

      {_other, _, _} ->
        {{400, error("idempotency_key_in_use")}, state}

      _ ->
        {result, state} = route(state, method, path, params)

        state =
          if key, do: put_in(state, [:idempotency, key], {params, path, result}), else: state

        {result, state}
    end
  end

  defp take_fault(agent, method, path),
    do: Agent.get_and_update(agent, &pop_fault(&1, method, path))

  defp pop_fault(state, method, path) do
    case Enum.split_while(state.faults, fn {m, p, _} ->
           not (m == method and match_path?(path, p))
         end) do
      {_, []} -> {nil, state}
      {before, [{_, _, fault} | rest]} -> {fault, %{state | faults: before ++ rest}}
    end
  end

  defp match_path?(path, %Regex{} = regex), do: Regex.match?(regex, path)
  defp match_path?(path, expected), do: path == expected

  defp reply(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end

  defp error(code), do: %{"error" => %{"type" => "invalid_request_error", "code" => code}}

  ## Routes

  defp route(state, "POST", "/v1/customers", params) do
    {id, state} = next_id(state, "cus")

    customer = %{
      "object" => "customer",
      "id" => id,
      "metadata" => params["metadata"] || %{},
      "livemode" => false
    }

    {{200, customer}, put_object(state, customer)}
  end

  defp route(state, "POST", "/v1/products", params) do
    {id, state} = next_id(state, "prod")

    product = %{
      "object" => "product",
      "id" => id,
      "name" => params["name"],
      "active" => true,
      "livemode" => false
    }

    {{200, product}, put_object(state, product)}
  end

  defp route(state, "POST", "/v1/prices", params) do
    {id, state} = next_id(state, "price")

    price = %{
      "object" => "price",
      "id" => id,
      "active" => true,
      "currency" => params["currency"],
      "unit_amount" => String.to_integer(params["unit_amount"]),
      "recurring" => %{
        "interval" => params["recurring"]["interval"],
        "interval_count" => String.to_integer(params["recurring"]["interval_count"] || "1")
      },
      "product" => params["product"],
      "livemode" => false
    }

    {{200, price}, put_object(state, price)}
  end

  defp route(state, "POST", "/v1/checkout/sessions", params) do
    {id, state} = next_id(state, "cs_test")
    price_id = params["line_items"]["0"]["price"]

    cond do
      state.objects[price_id] == nil ->
        {{400, error("resource_missing")}, state}

      String.to_integer(params["expires_at"]) < state.now + 1800 ->
        {{400, error("parameter_invalid_integer")}, state}

      true ->
        session = %{
          "object" => "checkout.session",
          "id" => id,
          "status" => "open",
          "mode" => params["mode"],
          "payment_status" => "unpaid",
          "customer" => params["customer"],
          "subscription" => nil,
          "invoice" => nil,
          "client_reference_id" => params["client_reference_id"],
          "url" => "https://checkout.stripe.com/c/pay/#{id}",
          "expires_at" => String.to_integer(params["expires_at"]),
          "livemode" => false,
          "_price" => price_id
        }

        {{200, public(session)}, put_object(state, session)}
    end
  end

  defp route(state, "GET", "/v1/checkout/sessions/" <> id, _params), do: fetch(state, id)

  defp route(state, "POST", "/v1/checkout/sessions/" <> rest, _params) do
    id = String.replace_suffix(rest, "/expire", "")

    case state.objects[id] do
      %{"status" => "open"} = session ->
        expired = Map.put(session, "status", "expired")
        {{200, public(expired)}, put_object(state, expired)}

      %{} ->
        {{400, error("checkout_session_not_open")}, state}

      nil ->
        {{404, error("resource_missing")}, state}
    end
  end

  defp route(state, "GET", "/v1/subscriptions/" <> id, _params), do: fetch(state, id)

  defp route(state, "POST", "/v1/subscriptions/" <> id, params) do
    case state.objects[id] do
      %{"status" => "canceled"} ->
        {{400, error("subscription_canceled")}, state}

      %{} = sub ->
        cancel = params["cancel_at_period_end"] == "true"
        [item] = sub["items"]["data"]

        updated =
          Map.merge(sub, %{
            "cancel_at_period_end" => cancel,
            "cancel_at" => if(cancel, do: item["current_period_end"])
          })

        {{200, updated}, put_object(state, updated)}

      nil ->
        {{404, error("resource_missing")}, state}
    end
  end

  defp route(state, "DELETE", "/v1/subscriptions/" <> id, _params) do
    case state.objects[id] do
      %{"status" => "canceled"} ->
        {{404, error("resource_missing")}, state}

      %{} = sub ->
        updated =
          Map.merge(sub, %{
            "status" => "canceled",
            "canceled_at" => state.now,
            "ended_at" => state.now,
            "cancellation_details" => %{"reason" => "cancellation_requested"}
          })

        {{200, updated}, put_object(state, updated)}

      nil ->
        {{404, error("resource_missing")}, state}
    end
  end

  defp route(state, "GET", "/v1/invoices/" <> id, _params), do: fetch(state, id)
  defp route(state, "GET", "/v1/payment_intents/" <> id, _params), do: fetch(state, id)
  defp route(state, "GET", "/v1/disputes/" <> id, _params), do: fetch(state, id)
  defp route(state, "GET", "/v1/accounts/" <> id, _params), do: fetch(state, id)
  defp route(state, "GET", "/v1/refunds/" <> id, _params), do: fetch(state, id)

  defp route(state, "GET", "/v1/invoice_payments", params) do
    data =
      state.objects
      |> Map.values()
      |> Enum.filter(fn p ->
        p["object"] == "invoice_payment" and
          (params["invoice"] == nil or p["invoice"] == params["invoice"]) and
          (params["status"] == nil or p["status"] == params["status"]) and
          (get_in(params, ["payment", "payment_intent"]) == nil or
             get_in(p, ["payment", "payment_intent"]) ==
               get_in(params, ["payment", "payment_intent"]))
      end)

    {{200, list(data)}, state}
  end

  defp route(state, "GET", "/v1/refunds", params) do
    data =
      state.objects
      |> Map.values()
      |> Enum.filter(&(&1["object"] == "refund" and &1["charge"] == params["charge"]))

    {{200, list(data)}, state}
  end

  defp route(state, "POST", "/v1/refunds", params) do
    pi_id = params["payment_intent"]

    case state.objects[pi_id] do
      %{"status" => "succeeded", "latest_charge" => charge} ->
        create_refund(
          state,
          pi_id,
          charge,
          String.to_integer(params["amount"]),
          params["metadata"] || %{}
        )

      _ ->
        {{400, error("resource_missing")}, state}
    end
  end

  defp route(state, "POST", "/v1/billing_portal/sessions", params) do
    if Enum.any?(state.objects, fn {id, _} -> id == params["customer"] end),
      do:
        {{200,
          %{
            "object" => "billing_portal.session",
            "url" => "https://billing.stripe.com/p/session/test_#{state.seq}",
            "livemode" => false
          }}, state},
      else: {{400, error("resource_missing")}, state}
  end

  defp route(state, "POST", "/v1/billing_portal/configurations", _params) do
    {id, state} = next_id(state, "bpc")
    {{200, %{"object" => "billing_portal.configuration", "id" => id, "livemode" => false}}, state}
  end

  defp route(state, _method, _path, _params), do: {{404, error("unknown_route")}, state}

  ## Object builders

  # A refund within what the payment's invoice paid, less earlier refunds.
  defp create_refund(state, pi_id, charge, amount, metadata) do
    objects = Map.values(state.objects)

    already =
      objects
      |> Enum.filter(&(&1["object"] == "refund" and &1["payment_intent"] == pi_id))
      |> Enum.map(& &1["amount"])
      |> Enum.sum()

    paid =
      Enum.find_value(objects, 0, fn o ->
        if o["object"] == "invoice_payment" and get_in(o, ["payment", "payment_intent"]) == pi_id,
          do: state.objects[o["invoice"]]["amount_paid"]
      end)

    if already + amount > paid do
      {{400, error("charge_already_refunded")}, state}
    else
      {id, state} = next_id(state, "re")
      refund = refund(id, pi_id, charge, amount, "pln", "succeeded", metadata)
      {{200, refund}, put_object(state, refund)}
    end
  end

  defp fetch(state, id) do
    case state.objects[id] do
      nil -> {{404, error("resource_missing")}, state}
      object -> {{200, public(object)}, state}
    end
  end

  defp public(object), do: Map.reject(object, fn {k, _} -> String.starts_with?(k, "_") end)

  defp subscription(id, customer, price, status, from, to, latest_invoice) do
    %{
      "object" => "subscription",
      "id" => id,
      "status" => status,
      "customer" => customer,
      "cancel_at_period_end" => false,
      "cancel_at" => nil,
      "canceled_at" => nil,
      "ended_at" => nil,
      "cancellation_details" => %{"reason" => nil},
      "latest_invoice" => latest_invoice,
      "livemode" => false,
      "items" => %{
        "object" => "list",
        "data" => [
          %{
            "id" => "si_#{id}",
            "price" => %{"id" => price["id"], "object" => "price"},
            "quantity" => 1,
            "current_period_start" => from,
            "current_period_end" => to
          }
        ]
      }
    }
  end

  defp invoice(%{
         id: id,
         customer: customer,
         subscription: sub_id,
         price: price,
         amount: amount,
         status: status,
         from: from,
         to: to,
         reason: reason
       }) do
    paid = status == "paid"

    %{
      "object" => "invoice",
      "id" => id,
      "status" => status,
      "customer" => customer,
      "currency" => price["currency"],
      "amount_due" => amount,
      "amount_paid" => if(paid, do: amount, else: 0),
      "amount_remaining" => if(paid, do: 0, else: amount),
      "total" => amount,
      "number" => "SF-#{String.slice(id, -6, 6)}",
      "billing_reason" => reason,
      "hosted_invoice_url" => "https://invoice.stripe.com/i/#{id}",
      "invoice_pdf" => "https://pay.stripe.com/invoice/#{id}/pdf",
      "attempt_count" => 1,
      "next_payment_attempt" => nil,
      "created" => from,
      "status_transitions" => %{"paid_at" => if(paid, do: from)},
      "livemode" => false,
      "parent" => %{
        "type" => "subscription_details",
        "subscription_details" => %{"subscription" => sub_id}
      },
      "lines" => %{
        "object" => "list",
        "data" => [
          %{
            "id" => "il_#{id}",
            "parent" => %{"type" => "subscription_item_details"},
            "period" => %{"start" => from, "end" => to},
            "pricing" => %{"price_details" => %{"price" => price["id"]}}
          }
        ]
      }
    }
  end

  defp payment_intent(id, status, charge),
    do: %{
      "object" => "payment_intent",
      "id" => id,
      "status" => status,
      "latest_charge" => charge,
      "livemode" => false
    }

  defp invoice_payment(id, invoice_id, pi_id, status) do
    %{
      "object" => "invoice_payment",
      "id" => id,
      "invoice" => invoice_id,
      "is_default" => true,
      "status" => status,
      "payment" => %{"type" => "payment_intent", "payment_intent" => pi_id},
      "livemode" => false
    }
  end

  defp refund(id, pi_id, charge, amount, currency, status, metadata) do
    %{
      "object" => "refund",
      "id" => id,
      "amount" => amount,
      "currency" => currency || "pln",
      "status" => status,
      "payment_intent" => pi_id,
      "charge" => charge,
      "reason" => nil,
      "metadata" => metadata,
      "livemode" => false
    }
  end

  defp list(data), do: %{"object" => "list", "data" => data, "has_more" => false}

  defp period(%{"recurring" => %{"interval" => "year"}}), do: 365 * 86_400
  defp period(_), do: 30 * 86_400

  defp next_id(state, prefix) do
    seq = state.seq + 1

    {"#{prefix}_#{String.pad_leading(Integer.to_string(seq), 8, "0")}#{rand()}",
     %{state | seq: seq}}
  end

  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp put_object(state, object), do: put_in(state, [:objects, object["id"]], object)

  defp update_object(state, id, fields),
    do: update_in(state, [:objects, id], &Map.merge(&1, fields))
end
