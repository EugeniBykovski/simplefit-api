defmodule SimpleFit.Email do
  @moduledoc """
  Transactional email boundary (delivery only).

  Domains build a `SimpleFit.Email.Message` and either deliver it now or,
  preferably, enqueue it:

      {:ok, message} = Message.new(to: user.email, subject: "...", text: "...")
      {:ok, _job} = Email.deliver_later(message)

  `deliver_later/1` runs delivery in the `mailers` Oban queue with bounded
  retries and a stable idempotency key per job, so a retry after a timeout
  does not send the email twice. Flows such as verification or password
  reset belong to their domains, not here.

  The adapter comes from configuration (`config :simple_fit, SimpleFit.Email`):
  `SimpleFit.Email.Resend` in production, a test adapter in test, and
  `SimpleFit.Email.Log` in development without a Resend API key.
  """

  alias SimpleFit.Email.{DeliveryWorker, Message}
  alias SimpleFit.Provider

  @typedoc "Provider receipt for a delivered message."
  @type receipt :: %{id: String.t()}

  @doc """
  Sends `message` through the provider. `config` is the application config
  for `SimpleFit.Email` (adapter options and the default `:from`).

  `opts` may contain `:idempotency_key`, which providers use to drop
  duplicate deliveries of the same message.
  """
  @callback deliver(Message.t(), config :: keyword(), opts :: keyword()) ::
              {:ok, receipt()} | {:error, Provider.error()}

  @doc """
  Delivers `message` synchronously. Prefer `deliver_later/1` from request
  handlers: it does not block the request and survives provider outages.

  ## Options

    * `:idempotency_key` - stable key for this message (max 256 characters)
  """
  @spec deliver(Message.t(), keyword()) :: {:ok, receipt()} | {:error, Provider.error()}
  def deliver(%Message{} = message, opts \\ []) do
    config = Application.get_env(:simple_fit, __MODULE__, [])
    adapter = Keyword.fetch!(config, :adapter)

    :telemetry.span([:simple_fit, :email, :deliver], %{adapter: adapter}, fn ->
      result = adapter.deliver(message, config, opts)
      {result, %{adapter: adapter, result: result_tag(result)}}
    end)
  end

  @doc """
  Enqueues delivery of `message` in the `mailers` queue.

  Returns the inserted `Oban.Job`. Message contents are stored in the job
  arguments until the job is pruned (see the Oban configuration).
  """
  @spec deliver_later(Message.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def deliver_later(%Message{} = message) do
    %{"message" => Message.to_map(message)}
    |> DeliveryWorker.new()
    |> Oban.insert()
  end

  defp result_tag({:ok, _receipt}), do: :ok
  defp result_tag({:error, reason}), do: reason
end
