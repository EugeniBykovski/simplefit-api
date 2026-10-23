defmodule SimpleFit.Coaching.LocalDevelopmentTest do
  @moduledoc """
  LOCAL DEVELOPMENT coaching mode activation (SF-81, ADR 0025): every
  condition is required, each failure is named, and the real activation
  refuses this (test) build whatever the opt-in says.
  """

  use SimpleFit.DataCase, async: false

  alias SimpleFit.Coaching.{LegalPolicy, LocalDevelopment}

  @local %{
    allowed: true,
    build_env: :dev,
    release?: false,
    opt_in: true,
    endpoint_ip: {127, 0, 0, 1},
    repo_host: "localhost",
    database: "simple_fit_dev",
    server_addr: "127.0.0.1/32",
    approved_databases: ["simple_fit_dev"]
  }

  describe "evaluate/1" do
    test "a local developer machine that opted in" do
      assert LocalDevelopment.evaluate(@local) == :ok
      assert LocalDevelopment.evaluate(%{@local | server_addr: nil}) == :ok
      assert LocalDevelopment.evaluate(%{@local | server_addr: "::1/128"}) == :ok
      assert LocalDevelopment.evaluate(%{@local | endpoint_ip: {0, 0, 0, 0, 0, 0, 0, 1}}) == :ok
      assert LocalDevelopment.evaluate(%{@local | repo_host: :unix_socket}) == :ok
      assert LocalDevelopment.evaluate(%{@local | repo_host: "127.0.0.1"}) == :ok
    end

    test "each missing condition alone refuses, and is named" do
      cases = [
        {%{allowed: false}, :not_allowed_in_this_build},
        {%{build_env: :prod}, :not_a_dev_build},
        {%{build_env: :test}, :not_a_dev_build},
        {%{release?: true}, :release},
        {%{opt_in: false}, :not_opted_in},
        # PHX_BIND_ALL=true
        {%{endpoint_ip: {0, 0, 0, 0}}, :endpoint_not_loopback},
        {%{endpoint_ip: {192, 168, 1, 20}}, :endpoint_not_loopback},
        {%{endpoint_ip: nil}, :endpoint_not_loopback},
        {%{repo_host: "db.internal"}, :repo_host_not_loopback},
        {%{repo_host: "10.0.0.5"}, :repo_host_not_loopback},
        {%{repo_host: nil}, :repo_host_not_loopback},
        # localhost forwarded to a remote server (an SSH tunnel, a proxy)
        {%{server_addr: "10.0.0.5/32"}, :database_server_not_local},
        {%{server_addr: :unknown}, :database_server_not_local},
        {%{database: "simple_fit_prod"}, :database_not_approved},
        {%{database: "simple_fit_local_e2e"}, :database_not_approved},
        {%{database: nil}, :database_not_approved},
        {%{approved_databases: []}, :database_not_approved}
      ]

      for {change, reason} <- cases do
        assert LocalDevelopment.evaluate(Map.merge(@local, change)) == {:error, [reason]},
               "#{inspect(change)} should refuse with #{reason}"
      end
    end

    test "a production node fails every build and opt-in condition at once" do
      production = %{
        @local
        | allowed: false,
          build_env: :prod,
          release?: true,
          opt_in: false,
          endpoint_ip: {0, 0, 0, 0},
          repo_host: "db.example.com",
          database: nil,
          server_addr: :unknown,
          approved_databases: []
      }

      assert {:error, reasons} = LocalDevelopment.evaluate(production)
      assert :not_allowed_in_this_build in reasons and :not_a_dev_build in reasons
      assert :release in reasons and :not_opted_in in reasons
    end
  end

  describe "the real activation" do
    setup do
      previous = Application.get_env(:simple_fit, LocalDevelopment)
      on_exit(fn -> Application.put_env(:simple_fit, LocalDevelopment, previous) end)
      on_exit(fn -> LocalDevelopment.put_active_for_test(false) end)
      :ok
    end

    test "refuses the test build even with an opt-in and an approved database name" do
      Application.put_env(:simple_fit, LocalDevelopment,
        allowed: true,
        opt_in: true,
        databases: ["simple_fit_test", "simple_fit_test_sf81"]
      )

      assert {:inactive, reasons} = LocalDevelopment.activate()
      assert :not_a_dev_build in reasons
      refute LocalDevelopment.active?()
      refute LegalPolicy.local_development?()
    end

    test "is off by default" do
      refute LocalDevelopment.active?()
      assert LegalPolicy.client_mode() == "approved"
    end
  end
end
