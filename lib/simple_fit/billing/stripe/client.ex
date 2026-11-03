defmodule SimpleFit.Billing.Stripe.Client do
  @moduledoc """
  The Stripe HTTP adapter (SF-102; ADR 0005): `https://api.stripe.com` over
  the canonical `SimpleFit.HTTP` client, no vendor SDK. Only
  `SimpleFit.Billing` reconciliation and operator modules call it.

  * Every request carries the pinned `Stripe-Version` and the secret key in
    the `authorization` header only; writes may carry an `Idempotency-Key`
    (a retried request returns the original result instead of creating a
    second object).
  * Request bodies are form-encoded with Stripe's bracket notation; URLs are
    built from constant paths and Stripe identifiers validated by
    `id!/2`, never from user input.
  * Every object answered must carry the configured mode's `livemode`; an
    object of the other mode is refused (`:invalid_request`) and logged
    without its identifiers.
  * Failures are `SimpleFit.Provider` reasons; bodies are never logged.
  * Answers are decoded into plain maps (`SimpleFit.Billing.Stripe.Objects`):
    no raw Stripe payload leaves the adapter.

  Tests stub the network with `req_options: [plug: {Req.Test, ...}]`.
  """

  require Logger

  alias SimpleFit.Billing.Stripe.{Config, Objects}
  alias SimpleFit.HTTP

  @base_url "https://api.stripe.com"
  @provider "stripe"

  @type result :: {:ok, map()} | {:error, SimpleFit.Provider.error()}

  @doc "`GET path` with query `params`, decoded by `decoder` (an `Objects` function name)."
  @spec get(String.t(), map() | keyword(), atom()) :: result()
  def get(path, params, decoder), do: request(:get, path, params, decoder, [])

  @doc "`POST path` with form `params`; `opts`: `:idempotency_key`."
  @spec post(String.t(), map(), atom(), keyword()) :: result()
  def post(path, params, decoder, opts \\ []), do: request(:post, path, params, decoder, opts)

  @doc "`DELETE path` with form `params`."
  @spec delete(String.t(), map(), atom()) :: result()
  def delete(path, params, decoder), do: request(:delete, path, params, decoder, [])

  @doc """
  A Stripe object id safe for a URL path: `prefix` followed by Stripe's id
  alphabet. Anything else raises (a programming error, never user input).
  """
  @spec id!(String.t(), String.t()) :: String.t()
  def id!(id, prefix) when is_binary(id) do
    if Regex.match?(~r/\A#{prefix}_[A-Za-z0-9_]{1,250}\z/, id),
      do: id,
      else: raise(ArgumentError, "not a Stripe #{prefix} id")
  end

  defp request(method, path, params, decoder, opts) do
    with {:ok, config} <- Config.fetch() do
      options =
        [
          base_url: @base_url,
          url: path,
          method: method,
          auth: {:bearer, config.secret_key},
          headers: [{"stripe-version", config.api_version} | idempotency(opts)]
        ] ++ body(method, params) ++ config.req_options

      :telemetry.span([:simple_fit, :billing, :stripe_request], %{method: method}, fn ->
        result =
          options
          |> HTTP.new()
          |> Req.request()
          |> HTTP.normalize(@provider)
          |> decode(decoder, config.mode)

        {result, %{method: method, result: tag(result)}}
      end)
    end
  end

  defp body(:get, params), do: [params: encode(params)]
  defp body(_method, params) when params == %{}, do: []
  defp body(_method, params), do: [form: encode(params)]

  defp idempotency(opts) do
    case opts[:idempotency_key] do
      key when is_binary(key) and byte_size(key) in 1..255 -> [{"idempotency-key", key}]
      _ -> []
    end
  end

  defp decode({:ok, %Req.Response{body: body}}, decoder, mode) when is_map(body) do
    with :ok <- same_mode(body, mode) do
      case apply(Objects, decoder, [body]) do
        {:ok, decoded} ->
          {:ok, decoded}

        :error ->
          Logger.warning("provider returned an unexpected response", provider: @provider)
          {:error, :unavailable}
      end
    end
  end

  defp decode({:ok, _unexpected}, _decoder, _mode) do
    Logger.warning("provider returned an unexpected response", provider: @provider)
    {:error, :unavailable}
  end

  defp decode({:error, _} = error, _decoder, _mode), do: error

  # Every object (or every listed object) must carry the configured mode.
  defp same_mode(%{"object" => "list", "data" => items}, mode) when is_list(items) do
    if Enum.all?(items, &(same_mode(&1, mode) == :ok)), do: :ok, else: mode_mismatch()
  end

  defp same_mode(%{"livemode" => livemode}, mode) when is_boolean(livemode) do
    if livemode == (mode == :live), do: :ok, else: mode_mismatch()
  end

  defp same_mode(_body, _mode), do: :ok

  defp mode_mismatch do
    Logger.warning("provider object of the other mode refused",
      provider: @provider,
      reason: :mode
    )

    {:error, :invalid_request}
  end

  defp tag({:ok, _}), do: :ok
  defp tag({:error, reason}), do: reason

  @doc false
  # Stripe's form encoding: nested maps and lists in bracket notation
  # (`line_items[0][price]`), booleans as `true`/`false`, nils dropped.
  @spec encode(map() | keyword()) :: [{String.t(), String.t()}]
  def encode(params), do: params |> Enum.flat_map(fn {k, v} -> pairs(to_string(k), v) end)

  defp pairs(_key, nil), do: []

  defp pairs(key, value) when is_map(value),
    do: Enum.flat_map(value, fn {k, v} -> pairs("#{key}[#{k}]", v) end)

  defp pairs(key, value) when is_list(value),
    do: value |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> pairs("#{key}[#{i}]", v) end)

  defp pairs(key, value) when is_boolean(value) or is_integer(value) or is_atom(value),
    do: [{key, to_string(value)}]

  defp pairs(key, value) when is_binary(value), do: [{key, value}]
end
