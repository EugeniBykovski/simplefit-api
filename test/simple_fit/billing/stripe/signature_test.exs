defmodule SimpleFit.Billing.Stripe.SignatureTest do
  use ExUnit.Case, async: true

  alias SimpleFit.Billing.Stripe.Signature

  @secret "whsec_notarealsecret"
  @body ~s({"id":"evt_1","object":"event"})
  @now ~U[2026-11-03 12:00:00Z]

  defp t, do: DateTime.to_unix(@now)

  test "accepts the exact raw body signed with the secret within the tolerance" do
    assert :ok = Signature.verify(@body, Signature.sign(@body, @secret, t()), @secret, @now, 300)

    assert :ok =
             Signature.verify(
               @body,
               Signature.sign(@body, @secret, t() - 300),
               @secret,
               @now,
               300
             )
  end

  test "accepts any v1 signature while a secret is rolled, and ignores v0" do
    "t=" <> rest = Signature.sign(@body, @secret, t())
    [_, good] = String.split(rest, ",v1=")
    header = "t=#{t()},v1=#{String.duplicate("a", 64)},v1=#{good},v0=#{String.duplicate("b", 64)}"
    assert :ok = Signature.verify(@body, header, @secret, @now, 300)
  end

  test "refuses a changed body, a re-serialized body, another secret or a missing signature" do
    header = Signature.sign(@body, @secret, t())

    assert {:error, :invalid_signature} =
             Signature.verify(@body <> "\n", header, @secret, @now, 300)

    reserialized = @body |> Jason.decode!() |> Jason.encode!(pretty: true)

    assert {:error, :invalid_signature} =
             Signature.verify(reserialized, header, @secret, @now, 300)

    assert {:error, :invalid_signature} =
             Signature.verify(@body, header, "whsec_othersecret", @now, 300)

    assert {:error, :missing_signature} = Signature.verify(@body, nil, @secret, @now, 300)
    assert {:error, :missing_signature} = Signature.verify(@body, "", @secret, @now, 300)
  end

  test "refuses stale or future timestamps (replays) and malformed headers" do
    assert {:error, :expired} =
             Signature.verify(
               @body,
               Signature.sign(@body, @secret, t() - 301),
               @secret,
               @now,
               300
             )

    assert {:error, :expired} =
             Signature.verify(
               @body,
               Signature.sign(@body, @secret, t() + 301),
               @secret,
               @now,
               300
             )

    assert {:error, :malformed_signature} =
             Signature.verify(@body, "t=abc,v1=#{String.duplicate("a", 64)}", @secret, @now, 300)

    assert {:error, :malformed_signature} =
             Signature.verify(
               @body,
               "t=1,t=2,v1=#{String.duplicate("a", 64)}",
               @secret,
               @now,
               300
             )

    assert {:error, :invalid_signature} = Signature.verify(@body, "t=#{t()}", @secret, @now, 300)
    assert {:error, :invalid_signature} = Signature.verify(@body, "garbage", @secret, @now, 300)
  end
end
