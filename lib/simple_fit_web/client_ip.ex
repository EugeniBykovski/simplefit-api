defmodule SimpleFitWeb.ClientIP do
  @moduledoc """
  The client IP address used for abuse limits (ADR 0012).

  `config :simple_fit, SimpleFitWeb.ClientIP, trusted_proxy_hops: n`
  (`TRUSTED_PROXY_HOPS`, default `0`):

    * `0` (default): the direct peer address (`conn.remote_ip`).
      `X-Forwarded-For` is ignored, so a client can never choose its own
      address. Behind a proxy every client then shares the proxy's address:
      IP limits become coarse, but per-target and per-challenge limits are
      unaffected.
    * `n > 0`: exactly `n` trusted proxies sit in front of the app, each
      appending the address it received the request from. The client is the
      `n`-th address from the right of the combined `X-Forwarded-For` list;
      anything further left was written by the client and is ignored. With
      fewer than `n` entries the peer address is used.

  Setting `n` higher than the real number of proxies lets clients spoof
  their address, so it is set only after the deployment topology is
  verified, and the app must not be reachable around the proxies.
  """

  alias Plug.Conn

  @max_hops 5

  @doc "The client address of `conn`, as a string."
  @spec get(Conn.t()) :: String.t()
  def get(%Conn{} = conn) do
    with hops when hops > 0 <- hops(),
         {:ok, address} <- forwarded(conn, hops) do
      format(address)
    else
      _direct_peer -> format(conn.remote_ip)
    end
  end

  @doc """
  Parses `TRUSTED_PROXY_HOPS`: unset or empty means `0`; otherwise an integer
  in `0..#{@max_hops}`. Anything else raises, so a deployment fails at boot.
  """
  @spec parse_hops!(String.t() | nil) :: non_neg_integer()
  def parse_hops!(nil), do: 0
  def parse_hops!(""), do: 0

  def parse_hops!(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {hops, ""} when hops in 0..@max_hops ->
        hops

      _invalid ->
        raise ArgumentError, "TRUSTED_PROXY_HOPS must be an integer between 0 and #{@max_hops}"
    end
  end

  defp hops do
    Application.get_env(:simple_fit, __MODULE__, [])[:trusted_proxy_hops] || 0
  end

  defp forwarded(conn, hops) do
    entries =
      conn
      |> Conn.get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)

    case Enum.at(entries, -hops) do
      entry when is_binary(entry) -> :inet.parse_strict_address(String.to_charlist(entry))
      nil -> :error
    end
  end

  # Plug allows a missing peer address (e.g. some test adapters); all such
  # requests share one bucket rather than escaping the limit.
  defp format(nil), do: "unknown"

  defp format(address) do
    case :inet.ntoa(address) do
      {:error, _invalid} -> "unknown"
      text -> to_string(text)
    end
  end
end
