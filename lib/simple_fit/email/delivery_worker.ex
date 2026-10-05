defmodule SimpleFit.Email.DeliveryWorker do
  @moduledoc """
  Delivers one `SimpleFit.Email.Message` from the `mailers` queue.

  Enqueue through `SimpleFit.Email.deliver_later/1`, not directly.

  * Each job uses the idempotency key `email-job-<id>`, so a retry after an
    ambiguous failure (timeout) cannot deliver the same email twice.
  * Retryable failures (`:timeout`, `:unavailable`, `:rate_limited`) are
    retried with Oban's exponential backoff, at most 5 attempts in total.
  * Permanent failures (`:invalid_request`, `:unauthorized`,
    `:configuration_error`) cancel the job immediately.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 5

  alias SimpleFit.Email
  alias SimpleFit.Email.Message
  alias SimpleFit.Provider

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"message" => serialized}}) do
    with {:ok, message} <- Message.from_map(serialized),
         {:ok, _receipt} <- Email.deliver(message, idempotency_key: "email-job-#{id}") do
      :ok
    else
      {:error, reason} ->
        if Provider.retryable?(reason), do: {:error, reason}, else: {:cancel, reason}
    end
  end
end
