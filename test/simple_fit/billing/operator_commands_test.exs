defmodule SimpleFit.Billing.OperatorCommandsTest do
  use ExUnit.Case, async: true

  alias SimpleFit.Billing.OperatorCommands

  test "a production build refuses the privileged commands; nothing else decides that" do
    refute OperatorCommands.available?(:prod)
    assert_raise Mix.Error, ~r/refused/, fn -> OperatorCommands.ensure_available!(:prod) end

    assert OperatorCommands.available?(:test)
    assert OperatorCommands.ensure_available!(:dev) == :ok
  end
end
