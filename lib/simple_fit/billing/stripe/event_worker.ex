defmodule SimpleFit.Billing.Stripe.EventWorker do
  @moduledoc """
  Processes one Stripe webhook inbox event (SF-102,
  `SimpleFit.Billing.Webhooks.process/1`). Arguments: the inbox row id only.
  Transient provider failures are retried with Oban's backoff, at most 10
  attempts (Stripe also redelivers, and the hourly sweep reconciles);
  processing is idempotent, so a retry never applies an effect twice.
  """

  use Oban.Worker, queue: :default, max_attempts: 10

  alias SimpleFit.Billing.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => id}, attempt: attempt, max_attempts: max}) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid |> Webhooks.process() |> outcome(uuid, attempt >= max)
      :error -> {:cancel, :invalid_args}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp outcome(:ok, _uuid, _last?), do: :ok

  defp outcome({:error, reason}, uuid, last?) do
    if last?, do: Webhooks.give_up(uuid)
    {:error, reason}
  end
end
