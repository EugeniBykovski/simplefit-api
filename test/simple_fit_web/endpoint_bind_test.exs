defmodule SimpleFitWeb.EndpointBindTest do
  use ExUnit.Case, async: true

  alias SimpleFitWeb.Endpoint

  test "PHX_BIND_ALL keeps loopback unless it is explicitly true" do
    for value <- [nil, "", " ", "false", "FALSE"] do
      assert Endpoint.parse_dev_bind_all!(value) == {127, 0, 0, 1}
    end

    assert Endpoint.parse_dev_bind_all!("true") == {0, 0, 0, 0}
    assert Endpoint.parse_dev_bind_all!(" TRUE ") == {0, 0, 0, 0}
  end

  test "PHX_BIND_ALL rejects anything else" do
    for value <- ["1", "yes", "0.0.0.0", "tru"] do
      assert_raise ArgumentError, ~r/PHX_BIND_ALL/, fn -> Endpoint.parse_dev_bind_all!(value) end
    end
  end
end
