defmodule SimpleFit.EmailTestAdapter do
  @moduledoc """
  `SimpleFit.Email` adapter for tests: never sends anything. Each delivered
  message is sent to the calling process (and its `$callers`) as
  `{:email_delivered, message, opts}`, so tests can `assert_received` it.

  Put `{:email_error, reason}` in the process dictionary to make the next
  deliveries fail with `reason`.
  """

  @behaviour SimpleFit.Email

  @impl true
  def deliver(message, _config, opts) do
    case Process.get(:email_error) do
      nil ->
        for pid <- [self() | Process.get(:"$callers", [])],
            do: send(pid, {:email_delivered, message, opts})

        {:ok, %{id: "test-" <> Integer.to_string(System.unique_integer([:positive]))}}

      reason ->
        {:error, reason}
    end
  end
end
