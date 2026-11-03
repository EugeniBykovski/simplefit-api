defmodule SimpleFit.Billing.Stripe.ClientTest do
  use ExUnit.Case, async: false

  alias SimpleFit.Billing.Stripe.Client
  alias SimpleFit.StripeFake

  setup do
    StripeFake.start!()
    :ok
  end

  test "form-encodes nested params in Stripe's bracket notation" do
    assert Client.encode(%{
             line_items: [%{price: "price_1", quantity: 1}],
             metadata: %{a: "b"},
             cancel_at_period_end: true,
             skip: nil
           })
           |> Enum.sort() == [
             {"cancel_at_period_end", "true"},
             {"line_items[0][price]", "price_1"},
             {"line_items[0][quantity]", "1"},
             {"metadata[a]", "b"}
           ]
  end

  test "sends the pinned version and the key; repeats with an idempotency key return the first answer" do
    assert {:ok, %{id: "cus_" <> _ = id}} =
             Client.post("/v1/customers", %{metadata: %{gym: "g"}}, :customer,
               idempotency_key: "k1"
             )

    assert {:ok, %{id: ^id}} =
             Client.post("/v1/customers", %{metadata: %{gym: "g"}}, :customer,
               idempotency_key: "k1"
             )

    assert {:error, :invalid_request} =
             Client.post("/v1/customers", %{metadata: %{gym: "other"}}, :customer,
               idempotency_key: "k1"
             )
  end

  test "refuses objects of the other mode and unexpected shapes; maps failures" do
    StripeFake.insert(%{
      "object" => "invoice",
      "id" => "in_live",
      "livemode" => true,
      "currency" => "pln"
    })

    assert {:error, :invalid_request} = Client.get("/v1/invoices/in_live", %{}, :invoice)

    StripeFake.insert(%{"object" => "invoice", "id" => "in_weird", "livemode" => false})
    assert {:error, :unavailable} = Client.get("/v1/invoices/in_weird", %{}, :invoice)

    assert {:error, :invalid_request} = Client.get("/v1/invoices/in_missing", %{}, :invoice)
    StripeFake.fail_next("GET", "/v1/invoices/in_missing", :timeout)
    assert {:error, :timeout} = Client.get("/v1/invoices/in_missing", %{}, :invoice)
  end

  test "ids must be Stripe ids before entering a URL" do
    assert Client.id!("sub_123", "sub") == "sub_123"
    assert_raise ArgumentError, fn -> Client.id!("sub_../../v1/charges", "sub") end
    assert_raise ArgumentError, fn -> Client.id!("in_1", "sub") end
  end
end
