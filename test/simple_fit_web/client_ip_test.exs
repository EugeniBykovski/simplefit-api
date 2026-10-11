defmodule SimpleFitWeb.ClientIPTest do
  @moduledoc """
  The client identity of abuse limits (ADR 0012, SF-29): never chosen by the
  client, and one key per IPv4 address or IPv6 /64 network.
  """

  # Not async: switches the trusted proxy configuration.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SimpleFitWeb.ClientIP

  defp with_hops(hops) do
    original = Application.get_env(:simple_fit, ClientIP)
    Application.put_env(:simple_fit, ClientIP, trusted_proxy_hops: hops)
    on_exit(fn -> Application.put_env(:simple_fit, ClientIP, original) end)
  end

  defp peer(address), do: %{conn(:post, "/") | remote_ip: address}

  describe "without trusted proxies (the default)" do
    test "every forwarding header is ignored: the client cannot choose its key" do
      conn =
        peer({192, 0, 2, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> put_req_header("x-real-ip", "203.0.113.10")
        |> put_req_header("forwarded", "for=203.0.113.11")

      assert ClientIP.limit_key(conn) == "192.0.2.1"
    end

    test "an IPv6 peer is keyed by its /64: rotating within it is one client" do
      a = peer({0x2001, 0xDB8, 0x1, 0x2, 0xAAAA, 0xBBBB, 0xCCCC, 0x1})
      b = peer({0x2001, 0xDB8, 0x1, 0x2, 0x1111, 0x2222, 0x3333, 0x4444})
      other_network = peer({0x2001, 0xDB8, 0x1, 0x3, 0, 0, 0, 1})

      assert ClientIP.limit_key(a) == "2001:db8:1:2::/64"
      assert ClientIP.limit_key(b) == ClientIP.limit_key(a)
      refute ClientIP.limit_key(other_network) == ClientIP.limit_key(a)
      # The address itself is still available, unchanged, to who needs it.
      assert ClientIP.get(a) == "2001:db8:1:2:aaaa:bbbb:cccc:1"
    end

    test "an IPv4-mapped IPv6 peer counts as its IPv4 address" do
      assert ClientIP.limit_key(peer({0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201})) == "192.0.2.1"
    end

    test "a request without a peer address shares one bucket instead of escaping limits" do
      assert ClientIP.limit_key(peer(nil)) == "unknown"
    end
  end

  describe "behind one trusted proxy" do
    setup do
      with_hops(1)
      :ok
    end

    test "the proxy-appended entry is the client; anything the client wrote is ignored" do
      conn =
        peer({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "6.6.6.6, 7.7.7.7, 203.0.113.9")

      assert ClientIP.limit_key(conn) == "203.0.113.9"
    end

    test "forwarding headers split over several lines are read as one list" do
      conn =
        peer({10, 0, 0, 1})
        |> Map.update!(:req_headers, fn headers ->
          headers ++
            [{"x-forwarded-for", "6.6.6.6"}, {"x-forwarded-for", "203.0.113.9"}]
        end)

      assert ClientIP.limit_key(conn) == "203.0.113.9"
    end

    test "a forwarded IPv6 client is keyed by its /64" do
      conn =
        peer({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "2001:db8:abcd:12:aaaa::1")

      assert ClientIP.limit_key(conn) == "2001:db8:abcd:12::/64"
    end

    test "a malformed or missing entry falls back to the proxy, never to client text" do
      for value <- ["garbage", "203.0.113.9:443", "[2001:db8::1]", "", "999.1.1.1"] do
        conn = peer({10, 0, 0, 1}) |> put_req_header("x-forwarded-for", value)
        assert ClientIP.limit_key(conn) == "10.0.0.1", "x-forwarded-for: #{inspect(value)}"
      end

      assert ClientIP.limit_key(peer({10, 0, 0, 1})) == "10.0.0.1"
    end
  end
end
