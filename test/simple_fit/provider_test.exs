defmodule SimpleFit.ProviderTest do
  use ExUnit.Case, async: true

  alias SimpleFit.Provider

  test "only transient failures are retryable" do
    assert Enum.filter(
             [
               :invalid_request,
               :unauthorized,
               :rate_limited,
               :timeout,
               :unavailable,
               :configuration_error
             ],
             &Provider.retryable?/1
           ) == [:rate_limited, :timeout, :unavailable]
  end
end
