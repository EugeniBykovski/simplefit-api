defmodule SimpleFit.Billing.Webhooks do
  @moduledoc """
  Stripe webhook ingestion and processing (SF-102;
  https://docs.stripe.com/webhooks).

  ## Ingestion (`ingest/3`, the HTTP request)

  1. The integration must be ready with a webhook secret (otherwise
     `:disabled`, answered `503` so Stripe retries later).
  2. The `Stripe-Signature` header is verified against the **exact raw
     body** (`SimpleFit.Billing.Stripe.Signature`), with the timestamp
     tolerance; anything else is `:invalid_signature` (`400`).
  3. The event envelope must be a Stripe event of the configured mode for
     SimpleFit's own account (Connect events, carrying `account`, are not
     accepted here): otherwise `:invalid_event` (`400`).
  4. The inbox row (ids and type, never the payload) and its processing job
     are inserted in one transaction; a repeated event id is a
     `:duplicate` and changes nothing. `2xx` is answered only after this
     commit; a storage failure is an error (`503`) so Stripe retries.

  ## Processing (`process/1`, an Oban job)

  Each handled type re-reads its object from Stripe through
  `SimpleFit.Billing.Reconciliation`; the event's own data is never applied.
  Unhandled types and objects that are not SimpleFit's are `ignored` with
  an outcome code; transient provider failures are retried by Oban
  (bounded); a permanent failure is `failed`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias SimpleFit.Billing.Reconciliation
  alias SimpleFit.Billing.Stripe.{Config, EventWorker, Signature, WebhookEvent}
  alias SimpleFit.{Clock, Repo}

  @unlogged [log: false]

  # The event types the endpoint subscribes to (`mix billing.stripe
  # webhook-events` prints this list for the Stripe endpoint setup).
  @handled %{
    "checkout.session.completed" => :checkout,
    "checkout.session.async_payment_succeeded" => :checkout,
    "checkout.session.async_payment_failed" => :checkout,
    "checkout.session.expired" => :checkout,
    "customer.subscription.created" => :subscription,
    "customer.subscription.updated" => :subscription,
    "customer.subscription.deleted" => :subscription,
    "invoice.finalized" => :invoice,
    "invoice.paid" => :invoice,
    "invoice.payment_failed" => :invoice,
    "invoice.payment_action_required" => :invoice,
    "invoice.voided" => :invoice,
    "invoice.marked_uncollectible" => :invoice,
    "payment_intent.payment_failed" => :payment_intent,
    "charge.refunded" => :charge,
    "refund.created" => :refund,
    "refund.updated" => :refund,
    "refund.failed" => :refund,
    "charge.dispute.created" => :dispute,
    "charge.dispute.updated" => :dispute,
    "charge.dispute.closed" => :dispute
  }

  @doc "The Stripe event types SimpleFit handles, sorted."
  @spec handled_types() :: [String.t()]
  def handled_types, do: @handled |> Map.keys() |> Enum.sort()

  @doc "Verifies and records one webhook delivery (see the moduledoc)."
  @spec ingest(binary() | nil, String.t() | nil, map()) ::
          {:ok, :accepted | :duplicate}
          | {:error, :disabled | :invalid_signature | :invalid_event | :storage}
  def ingest(raw_body, signature, event) do
    with {:ok, config} <- ready(),
         :ok <- verify(raw_body, signature, config),
         {:ok, envelope} <- envelope(event, config.mode) do
      store(envelope)
    end
    |> tap(&emit(:ingest, &1))
  end

  defp ready do
    case Config.fetch() do
      {:ok, %{webhook_secret: secret} = config} when is_binary(secret) -> {:ok, config}
      _ -> {:error, :disabled}
    end
  end

  defp verify(raw_body, signature, config) when is_binary(raw_body) do
    case Signature.verify(
           raw_body,
           signature,
           config.webhook_secret,
           Clock.utc_now(),
           config.webhook_tolerance
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("webhook signature refused", provider: "stripe", reason: reason)
        {:error, :invalid_signature}
    end
  end

  defp verify(_raw_body, _signature, _config), do: {:error, :invalid_signature}

  defp envelope(
         %{
           "object" => "event",
           "id" => "evt_" <> _ = id,
           "type" => type,
           "livemode" => livemode,
           "created" => created
         } = event,
         mode
       )
       when is_binary(type) and is_boolean(livemode) and is_integer(created) do
    object = get_in(event, ["data", "object"]) || %{}

    cond do
      livemode != (mode == :live) ->
        invalid(:mode)

      Map.get(event, "account") != nil ->
        invalid(:account)

      not Regex.match?(~r/\Aevt_[A-Za-z0-9_]{1,250}\z/, id) ->
        invalid(:event_id)

      true ->
        {:ok,
         %{
           mode: mode,
           stripe_event_id: id,
           event_type: String.slice(type, 0, 100),
           object_type: string(object["object"]),
           object_id: string(object["id"]),
           event_created_at: DateTime.from_unix!(created * 1_000_000, :microsecond)
         }}
    end
  end

  defp envelope(_event, _mode), do: invalid(:envelope)

  defp invalid(reason) do
    Logger.warning("webhook event refused", provider: "stripe", reason: reason)
    {:error, :invalid_event}
  end

  defp string(value) when is_binary(value), do: String.slice(value, 0, 255)
  defp string(_), do: nil

  defp store(envelope) do
    case Repo.transaction(fn -> insert_event(envelope) end, @unlogged) do
      {:ok, outcome} -> {:ok, outcome}
      {:error, _} -> {:error, :storage}
    end
  rescue
    exception in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("webhook inbox unavailable",
        provider: "stripe",
        error_type: inspect(exception.__struct__)
      )

      {:error, :storage}
  end

  # The inbox row and its job commit together; a repeated event id inserts
  # nothing (and enqueues nothing).
  defp insert_event(envelope) do
    %WebhookEvent{}
    |> Ecto.Changeset.change(Map.put(envelope, :status, :received))
    |> Repo.insert(
      Keyword.merge(@unlogged,
        on_conflict: :nothing,
        conflict_target: [:mode, :stripe_event_id]
      )
    )
    |> enqueue()
  end

  defp enqueue({:ok, %WebhookEvent{id: id}}) do
    if Repo.exists?(from(e in WebhookEvent, where: e.id == ^id)) do
      {:ok, _job} = Oban.insert(EventWorker.new(%{"event_id" => id}))
      :accepted
    else
      :duplicate
    end
  end

  defp enqueue({:error, _}), do: Repo.rollback(:storage)

  @doc "Processes one inbox event (the Oban job; see the moduledoc)."
  @spec process(Ecto.UUID.t()) :: :ok | {:error, SimpleFit.Provider.error()}
  def process(event_id) do
    case Repo.get(WebhookEvent, event_id, @unlogged) do
      %WebhookEvent{status: :received} = event ->
        event = change!(event, attempts: event.attempts + 1)

        event
        |> dispatch()
        |> finish(event)

      _ ->
        :ok
    end
  end

  defp dispatch(%WebhookEvent{event_type: type, object_id: id}) when is_binary(id) do
    case Map.get(@handled, type) do
      nil -> {:ignore, :unhandled_type}
      kind -> sync(kind, id)
    end
  end

  defp dispatch(_event), do: {:ignore, :no_object}

  # Each kind re-reads its object from Stripe; an id of an unexpected shape
  # is ignored (a platform refund `pyr_` has no SaaS invoice).
  defp sync(:checkout, "cs_" <> _ = id), do: Reconciliation.sync_checkout_session(id)
  defp sync(:subscription, "sub_" <> _ = id), do: Reconciliation.sync_stripe_subscription(id)
  defp sync(:invoice, "in_" <> _ = id), do: Reconciliation.sync_invoice(id)
  defp sync(:payment_intent, "pi_" <> _ = id), do: Reconciliation.sync_payment_intent(id)
  defp sync(:charge, "ch_" <> _ = id), do: Reconciliation.sync_charge_refunds(id)
  defp sync(:refund, "re_" <> _ = id), do: Reconciliation.sync_refund(id)
  defp sync(:dispute, "dp_" <> _ = id), do: Reconciliation.sync_dispute(id)
  defp sync(:dispute, "du_" <> _ = id), do: Reconciliation.sync_dispute(id)
  defp sync(_kind, _id), do: {:ignore, :unexpected_object}

  defp finish({:ok, outcome}, event) do
    change!(event,
      status: :processed,
      outcome: Atom.to_string(outcome),
      processed_at: Clock.utc_now()
    )

    emit(:process, {:ok, outcome})
  end

  defp finish({:ignore, reason}, event) do
    change!(event,
      status: :ignored,
      outcome: Atom.to_string(reason),
      processed_at: Clock.utc_now()
    )

    emit(:process, {:ok, reason})
  end

  defp finish({:error, reason}, event) do
    if SimpleFit.Provider.retryable?(reason) do
      emit(:process, {:error, reason})
      {:error, reason}
    else
      change!(event,
        status: :failed,
        outcome: Atom.to_string(reason),
        processed_at: Clock.utc_now()
      )

      emit(:process, {:error, reason})
    end
  end

  @doc "Marks a received event failed after its last attempt (the worker's give-up path)."
  @spec give_up(Ecto.UUID.t()) :: :ok
  def give_up(event_id) do
    case Repo.get(WebhookEvent, event_id, @unlogged) do
      %WebhookEvent{status: :received} = event ->
        change!(event,
          status: :failed,
          outcome: "retries_exhausted",
          processed_at: Clock.utc_now()
        )

        :ok

      _ ->
        :ok
    end
  end

  defp change!(struct, changes),
    do: struct |> Ecto.Changeset.change(changes) |> Repo.update!(@unlogged)

  # Outcomes only: no event, object or customer id.
  defp emit(stage, result) do
    outcome =
      case result do
        {:ok, value} -> value
        {:error, reason} -> reason
      end

    :telemetry.execute([:simple_fit, :billing, :webhook], %{count: 1}, %{
      stage: stage,
      outcome: outcome
    })

    :ok
  end
end
