defmodule SimpleFit.Billing.Stripe.SweepWorker do
  @moduledoc """
  Hourly Stripe reconciliation sweep (SF-102; `Oban.Plugins.Cron`), so a
  missed or failed webhook never leaves a subscription stale: every
  subscription with a live Stripe link not synced for six hours or whose
  paid period ended, and every pending intent with a checkout, is
  reconciled (at most 100 per run, oldest first). Does nothing while the
  integration is disabled.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 300]

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Billing.{GymSubscription, Reconciliation}
  alias SimpleFit.Billing.Stripe.{Checkout, Config, SubscriptionLink}
  alias SimpleFit.{Clock, Repo}

  @batch 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Config.fetch() do
      {:ok, config} ->
        config.mode
        |> due(Clock.utc_now())
        |> Enum.each(&Reconciliation.reconcile_subscription/1)

      {:error, _} ->
        :ok
    end

    :ok
  end

  @doc false
  @spec due(:test | :live, DateTime.t()) :: [Ecto.UUID.t()]
  def due(mode, now) do
    stale = DateTime.add(now, -6 * 3600)

    linked =
      Repo.all(
        from(l in SubscriptionLink,
          join: s in GymSubscription,
          on: s.id == l.subscription_id,
          where:
            l.mode == ^mode and l.provider_status not in [:canceled, :incomplete_expired] and
              (l.synced_at < ^stale or s.current_period_end <= ^now or
                 s.status == :pending_activation),
          order_by: [asc: l.synced_at],
          limit: @batch,
          select: l.subscription_id
        ),
        log: false
      )

    checkouts =
      Repo.all(
        from(c in Checkout,
          where: c.mode == ^mode and c.status in [:creating, :open, :completed],
          join: s in GymSubscription,
          on: s.id == c.subscription_id,
          where: s.status == :pending_activation,
          order_by: [asc: c.updated_at],
          limit: @batch,
          select: c.subscription_id
        ),
        log: false
      )

    Enum.uniq(linked ++ checkouts)
  end
end
