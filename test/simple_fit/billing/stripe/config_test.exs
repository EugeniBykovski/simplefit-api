defmodule SimpleFit.Billing.Stripe.ConfigTest do
  use ExUnit.Case, async: false

  alias SimpleFit.Billing.Stripe.Config

  @test_key "sk_test_notarealkey"
  @live_key "sk_live_notarealkey"

  test "defaults: disabled, test mode, the pinned API version" do
    config = Config.parse!(%{}, :prod)
    assert config[:enabled] == false
    assert config[:mode] == :test
    assert config[:api_version] == "2026-10-28.endive"
    assert config[:connect_enabled] == false
  end

  test "a key of the other mode fails boot" do
    assert_raise ArgumentError, ~r/does not belong/, fn ->
      Config.parse!(%{"STRIPE_SECRET_KEY" => @live_key}, :dev)
    end

    assert_raise ArgumentError, ~r/does not belong/, fn ->
      Config.parse!(
        %{
          "STRIPE_MODE" => "live",
          "STRIPE_SECRET_KEY" => @test_key,
          "STRIPE_LIVE_APPROVAL" => "REL-1"
        },
        :prod
      )
    end
  end

  test "live mode is refused outside production and needs a release approval" do
    assert_raise ArgumentError, ~r/outside a production build/, fn ->
      Config.parse!(%{"STRIPE_MODE" => "live"}, :dev)
    end

    assert_raise ArgumentError, ~r/STRIPE_LIVE_APPROVAL/, fn ->
      Config.parse!(%{"STRIPE_MODE" => "live", "STRIPE_BILLING_ENABLED" => "true"}, :prod)
    end

    assert Config.parse!(
             %{
               "STRIPE_MODE" => "live",
               "STRIPE_BILLING_ENABLED" => "true",
               "STRIPE_SECRET_KEY" => @live_key,
               "STRIPE_LIVE_APPROVAL" => "REL-2026-11"
             },
             :prod
           )[:mode] == :live
  end

  test "malformed values fail boot; preview versions are refused" do
    for {name, value} <- [
          {"STRIPE_WEBHOOK_SECRET", "secret"},
          {"STRIPE_ACCOUNT_ID", "account"},
          {"STRIPE_API_VERSION", "2026-10-28.preview-x"},
          {"STRIPE_PORTAL_CONFIGURATION_ID", "portal"},
          {"STRIPE_BILLING_ENABLED", "yes"},
          {"STRIPE_MODE", "sandbox"}
        ] do
      assert_raise ArgumentError, fn -> Config.parse!(%{name => value}, :dev) end
    end
  end

  test "status fails closed while enabled without a key or with a key of the other mode" do
    original = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe)

    try do
      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, enabled: true, mode: :test)
      assert {:misconfigured, [:secret_key]} = Config.status()
      assert {:error, :configuration_error} = Config.fetch()

      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe,
        enabled: true,
        mode: :test,
        secret_key: @live_key
      )

      assert {:misconfigured, [:secret_key]} = Config.status()

      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe,
        enabled: true,
        mode: :live,
        secret_key: @live_key
      )

      assert {:misconfigured, [:live_approval]} = Config.status()

      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe,
        enabled: false,
        mode: :test,
        secret_key: @test_key
      )

      assert :disabled = Config.status()
      assert Config.mode() == nil
    after
      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, original)
    end
  end
end
