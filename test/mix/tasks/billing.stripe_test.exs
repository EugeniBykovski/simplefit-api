defmodule Mix.Tasks.Billing.StripeTest do
  # Not async: switches the Mix shell and the Stripe configuration.
  use SimpleFit.DataCase, async: false

  import SimpleFit.BillingHelpers
  import SimpleFit.GymHelpers

  alias Mix.Tasks.Billing.Stripe, as: Task
  alias SimpleFit.Billing.Connect
  alias SimpleFit.Billing.Stripe.{ConnectedAccount, PriceMapping}
  alias SimpleFit.{Repo, StripeFake}

  setup do
    StripeFake.start!()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "status prints readiness without secrets; webhook-events lists the handled types" do
    Task.run(["status"])
    assert_received {:mix_shell, :info, [status]}
    assert status =~ "stripe: ready (mode test, api 2026-10-28.endive"
    refute status =~ "sk_test"
    refute status =~ "whsec_"

    assert_received {:mix_shell, :info,
                     ["stripe account: mode test confirmed by Stripe, account match"]}

    Task.run(["webhook-events"])
    assert_received {:mix_shell, :info, ["charge.dispute.closed"]}
  end

  describe "status asks Stripe about the key (SF-138)" do
    setup do
      original = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe)
      on_exit(fn -> Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, original) end)
      %{original: original}
    end

    test "a key of another account fails", ctx do
      Application.put_env(
        :simple_fit,
        SimpleFit.Billing.Stripe,
        Keyword.put(ctx.original, :account_id, "acct_someoneelse")
      )

      assert_raise Mix.Error, ~r/not STRIPE_ACCOUNT_ID/, fn -> Task.run(["status"]) end
    end

    test "without STRIPE_ACCOUNT_ID the account is reported as not checked", ctx do
      Application.put_env(
        :simple_fit,
        SimpleFit.Billing.Stripe,
        Keyword.delete(ctx.original, :account_id)
      )

      Task.run(["status"])
      assert_received {:mix_shell, :info, ["stripe: ready" <> _]}

      assert_received {:mix_shell, :info,
                       ["stripe account: mode test confirmed by Stripe, account not_configured"]}
    end

    test "a live answer to a test key fails, whatever the key's prefix says" do
      Req.Test.stub(StripeFake, fn conn ->
        Req.Test.json(conn, %{"object" => "balance", "livemode" => true})
      end)

      assert_raise Mix.Error, ~r/did not confirm the key \(:invalid_request\)/, fn ->
        Task.run(["status"])
      end
    end

    test "an expired key fails, naming no secret" do
      Req.Test.stub(StripeFake, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"type" => "invalid_request_error"}})
      end)

      error = assert_raise Mix.Error, ~r/did not confirm the key/, fn -> Task.run(["status"]) end
      refute error.message =~ "sk_test"
    end
  end

  test "map-price and setup-portal need an operator and print ids only" do
    version = published_plan!()

    assert_raise Mix.Error, ~r/--operator NAME is required/, fn ->
      Task.run(["map-price", price(version).id])
    end

    Task.run(["map-price", price(version).id, "--operator", "ops"])
    assert_received {:mix_shell, :info, ["mapped: " <> line]}
    assert line =~ "(test, 14900 PLN/month)"
    assert Repo.get_by!(PriceMapping, price_version_id: price(version).id).mapped_by == "ops"

    Task.run(["setup-portal", "--operator", "ops"])
    assert_received {:mix_shell, :info, ["portal configuration: bpc_" <> _]}

    [{_, _, params}] =
      Enum.filter(
        StripeFake.requests(),
        &match?({"POST", "/v1/billing_portal/configurations", _}, &1)
      )

    assert params["features"]["subscription_cancel"]["enabled"] == "false"
    assert params["features"]["subscription_update"]["enabled"] == "false"
    assert params["features"]["payment_method_update"]["enabled"] == "true"
  end

  test "refund needs an approval and a known reason; unknown commands are refused" do
    assert_raise Mix.Error, ~r/--approval REF is required/, fn ->
      Task.run(["refund", "in_1", "--operator", "ops"])
    end

    assert_raise Mix.Error, ~r/--reason must be one of/, fn ->
      Task.run(["refund", "in_1", "--operator", "ops", "--approval", "A", "--reason", "whim"])
    end

    assert_raise Mix.Error, ~r/refused: :not_found/, fn ->
      Task.run(["refund", "in_1", "--operator", "ops", "--approval", "A"])
    end

    assert_raise Mix.Error, ~r/usage/, fn -> Task.run(["charge"]) end
  end

  test "Connect: links an existing test account, syncs it, never enables member payments" do
    owner = registered!("stripe-connect")
    gym = completed_gym!(owner)
    account = StripeFake.account()

    Task.run(["link-account", gym.id, account, "--operator", "ops"])
    assert_received {:mix_shell, :info, ["linked: " <> _]}

    assert %ConnectedAccount{charges_enabled: false, requirements_due_count: 1, linked_by: "ops"} =
             Repo.get_by!(ConnectedAccount, stripe_account_id: account)

    StripeFake.put(account, %{
      "charges_enabled" => true,
      "payouts_enabled" => true,
      "requirements" => %{"currently_due" => []}
    })

    Task.run(["sync-account", account])
    assert_received {:mix_shell, :info, ["synced: " <> line]}
    assert line =~ "charges true, payouts true, due 0"

    assert_raise Mix.Error, ~r/already_linked/, fn ->
      Task.run(["link-account", gym.id, StripeFake.account(), "--operator", "ops"])
    end

    assert {:unavailable, reasons} = Connect.member_payments(gym.id)
    assert :merchant_of_record in reasons

    original = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe)

    Application.put_env(
      :simple_fit,
      SimpleFit.Billing.Stripe,
      Keyword.put(original, :connect_enabled, false)
    )

    try do
      assert_raise Mix.Error, ~r/disabled/, fn ->
        Task.run([
          "link-account",
          completed_gym!(owner).id,
          StripeFake.account(),
          "--operator",
          "ops"
        ])
      end
    after
      Application.put_env(:simple_fit, SimpleFit.Billing.Stripe, original)
    end
  end
end
