defmodule SimpleFit.Identity.KeyCache do
  @moduledoc """
  Cache of an identity provider's published ID-token signing keys (JWKS),
  shared infrastructure of `SimpleFit.Identity` providers (ADR 0013, ADR
  0014). It only fetches, parses and caches RSA keys; every claim check stays
  in the provider's verifier.

  Each provider starts its own named cache (`SimpleFit.Identity.Google.Keys`,
  `SimpleFit.Identity.Apple.Keys`) with:

    * `:name` - the registered process name (also the `Req.Test` stub name)
    * `:base_url` and `:path` - the JWKS location (never user-supplied)
    * `:provider` - the `SimpleFit.HTTP` provider label (`"google_jwks"`)
    * `:event` - the telemetry event emitted when a refresh fails
    * `:config` - the application env key holding test `:req_options`

  Keys are fetched through `SimpleFit.HTTP` (TLS verification, 5 s connect /
  15 s receive timeouts, no retries, no redirects). One process per provider
  serializes refreshes, so concurrent requests never stampede the provider.

    * Keys are valid until the response's `Cache-Control: max-age` elapses,
      or 300 s when it has none (Apple sends `no-store`, which would mean a
      fetch per request, so it also gets the default).
    * An unknown `kid` triggers one refresh, at most once per 60 s, so
      tokens with random key ids cannot cause a fetch storm.
    * A failed or malformed refresh never replaces keys that are still
      valid; there is no grace period beyond their lifetime.
    * Without valid keys, lookups fail with `:unavailable` (fail closed); a
      failed refresh is retried at most every 5 s.
  """

  use GenServer

  require Logger

  alias SimpleFit.HTTP

  @default_max_age 300
  @unknown_kid_throttle 60
  @failure_backoff 5

  @typedoc "Why no key could be returned."
  @type error :: :unknown_key | :unavailable

  ## API

  @doc false
  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, Map.new(opts), name: Keyword.fetch!(opts, :name))

  @doc """
  The public key for `kid` from the cache `name`:

    * `{:ok, jwk}`
    * `{:error, :unknown_key}` - the provider's current keys do not include `kid`
    * `{:error, :unavailable}` - no valid keys could be obtained
  """
  @spec fetch(GenServer.name(), String.t()) :: {:ok, JOSE.JWK.t()} | {:error, error()}
  def fetch(name, kid) when is_binary(kid), do: GenServer.call(name, {:fetch, kid}, 20_000)

  @doc "Forgets every cached key (operations and tests)."
  @spec flush(GenServer.name()) :: :ok
  def flush(name), do: GenServer.call(name, :flush)

  ## Server

  @impl GenServer
  def init(opts), do: {:ok, empty(opts)}

  @impl GenServer
  def handle_call(:flush, _from, state), do: {:reply, :ok, empty(state.opts)}

  def handle_call({:fetch, kid}, _from, state) do
    now = now()

    cond do
      valid?(state, now) and Map.has_key?(state.keys, kid) ->
        {:reply, {:ok, Map.fetch!(state.keys, kid)}, state}

      valid?(state, now) and not refresh_allowed?(state, now) ->
        {:reply, {:error, :unknown_key}, state}

      # Outage backoff: without valid keys, a refresh that just failed is not
      # retried for every request (each would wait for the timeouts).
      not valid?(state, now) and recently_failed?(state, now) ->
        {:reply, {:error, :unavailable}, state}

      true ->
        state = refresh(state, now)
        {:reply, lookup(state, kid, now), state}
    end
  end

  defp lookup(state, kid, now) do
    cond do
      not valid?(state, now) -> {:error, :unavailable}
      Map.has_key?(state.keys, kid) -> {:ok, Map.fetch!(state.keys, kid)}
      # The provider answered and does not know this key.
      state.last_refresh_ok? -> {:error, :unknown_key}
      # The refresh failed: the key may be new, so this is an outage.
      true -> {:error, :unavailable}
    end
  end

  defp refresh(state, now) do
    state = %{state | last_attempt: now}

    case download(state.opts) do
      {:ok, keys, max_age} ->
        %{state | keys: keys, expires_at: now + max_age, last_refresh_ok?: true}

      {:error, reason} ->
        Logger.warning("identity provider signing keys refresh failed",
          provider: state.opts.provider,
          reason: reason
        )

        :telemetry.execute(state.opts.event, %{count: 1}, %{reason: reason})

        # Keys that are still valid survive a failed refresh.
        %{state | last_refresh_ok?: false}
    end
  end

  defp download(opts) do
    request = HTTP.new([base_url: opts.base_url] ++ req_options(opts))

    with {:ok, response} <- request |> Req.get(url: opts.path) |> HTTP.normalize(opts.provider),
         {:ok, keys} <- parse_keys(response.body) do
      {:ok, keys, max_age(response)}
    end
  end

  defp parse_keys(%{"keys" => [_ | _] = keys}) do
    parsed =
      for %{"kid" => kid, "kty" => "RSA", "n" => n, "e" => e} = key <- keys,
          is_binary(kid) and is_binary(n) and is_binary(e) and key["use"] in [nil, "sig"] and
            key["alg"] in [nil, "RS256"],
          into: %{} do
        {kid, JOSE.JWK.from_map(%{"kty" => "RSA", "n" => n, "e" => e})}
      end

    if map_size(parsed) > 0, do: {:ok, parsed}, else: {:error, :malformed}
  rescue
    _invalid_key -> {:error, :malformed}
  end

  defp parse_keys(_body), do: {:error, :malformed}

  defp max_age(response) do
    response
    |> Req.Response.get_header("cache-control")
    |> Enum.find_value(@default_max_age, fn value ->
      case Regex.run(~r/max-age=(\d+)/, value) do
        [_, seconds] -> String.to_integer(seconds)
        nil -> nil
      end
    end)
  end

  defp valid?(%{expires_at: nil}, _now), do: false
  defp valid?(%{expires_at: expires_at}, now), do: now < expires_at

  defp refresh_allowed?(%{last_attempt: nil}, _now), do: true
  defp refresh_allowed?(%{last_attempt: last}, now), do: now - last >= @unknown_kid_throttle

  defp recently_failed?(%{last_attempt: nil}, _now), do: false

  defp recently_failed?(%{last_attempt: last, last_refresh_ok?: ok?}, now),
    do: not ok? and now - last < @failure_backoff

  defp empty(opts),
    do: %{opts: opts, keys: %{}, expires_at: nil, last_attempt: nil, last_refresh_ok?: false}

  defp req_options(opts),
    do: Application.get_env(:simple_fit, opts.config, [])[:req_options] || []

  defp now, do: System.os_time(:second)
end
