defmodule SimpleFit.Provider do
  @moduledoc """
  Conventions shared by every external provider boundary (`SimpleFit.Storage`,
  `SimpleFit.Email`, and future `Payments`, `Identity`, `Push`).

  A boundary is a SimpleFit-owned module named for the capability. It defines
  a behaviour, validates input, resolves the configured adapter and calls it.
  Adapters are the only modules that know about a vendor. Domain code calls
  the boundary, never an adapter or a vendor library.

  Adapters translate every vendor or network failure into one of the reasons
  below. Raw vendor responses, HTTP bodies, credentials and signed URLs never
  cross the boundary and are never logged.

    * `:invalid_request` - the request was rejected as invalid (our bug or bad
      input); retrying the same request will not help.
    * `:unauthorized` - the provider rejected our credentials or permissions.
    * `:rate_limited` - the provider asked us to slow down; retry later.
    * `:timeout` - no answer in time; the outcome is unknown.
    * `:unavailable` - the provider failed or could not be reached.
    * `:configuration_error` - the provider is not configured in this
      environment (fail closed: nothing was sent).
  """

  @typedoc "Normalized failure reason returned by every provider boundary."
  @type error ::
          :invalid_request
          | :unauthorized
          | :rate_limited
          | :timeout
          | :unavailable
          | :configuration_error

  @retryable [:rate_limited, :timeout, :unavailable]

  @doc """
  Whether retrying later may succeed. `:invalid_request`, `:unauthorized` and
  `:configuration_error` need a code or configuration change instead.
  """
  @spec retryable?(error()) :: boolean()
  def retryable?(reason), do: reason in @retryable
end
