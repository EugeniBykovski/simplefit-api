defmodule SimpleFit.BillingTestProvider do
  @moduledoc """
  The test environment's trusted provider (SF-101): lets tests exercise the
  active, scheduled and expired states of the lifecycle. Registered only in
  `config/test.exs`; compiled only in test (`test/support`). A payload is
  `%{reference: String.t(), period_start: DateTime.t(), period_end: DateTime.t()}`,
  or `:fail` for a provider error.
  """

  @behaviour SimpleFit.Billing.Activation

  @impl true
  def verify(:fail), do: {:error, :unavailable}

  def verify(%{reference: reference, period_start: from, period_end: to}),
    do: {:ok, %{reference: reference, period_start: from, period_end: to}}

  def verify(_), do: {:error, :invalid_request}
end
