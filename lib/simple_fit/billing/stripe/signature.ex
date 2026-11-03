defmodule SimpleFit.Billing.Stripe.Signature do
  @moduledoc """
  Stripe webhook signature verification (SF-102;
  https://docs.stripe.com/webhooks/signature). Pure: no I/O.

  The `Stripe-Signature` header is `t=<unix seconds>,v1=<hex>[,v1=...][,v0=...]`.
  The signed payload is `"<t>.<exact raw request body>"`; the expected
  signature is its HMAC-SHA256 under the endpoint's secret, hex encoded.
  Any `v1` signature may match (several exist while a secret is rolled);
  comparison is constant time. `v0` (test-only scheme) is ignored. The
  timestamp must be within `tolerance` seconds of now, in either direction,
  so a captured delivery cannot be replayed later.

  Errors never contain the secret, the expected signature or the body.
  """

  @type error :: :missing_signature | :malformed_signature | :expired | :invalid_signature

  @doc "Verifies `raw_body` against `header` with `secret` at `now`."
  @spec verify(binary(), String.t() | nil, String.t(), DateTime.t(), pos_integer()) ::
          :ok | {:error, error()}
  def verify(_raw_body, nil, _secret, _now, _tolerance), do: {:error, :missing_signature}
  def verify(_raw_body, "", _secret, _now, _tolerance), do: {:error, :missing_signature}

  def verify(raw_body, header, secret, %DateTime{} = now, tolerance)
      when is_binary(raw_body) and is_binary(header) and is_binary(secret) and secret != "" do
    with {:ok, timestamp, signatures} <- parse(header),
         :ok <- fresh(timestamp, now, tolerance) do
      expected =
        :crypto.mac(:hmac, :sha256, secret, [Integer.to_string(timestamp), ".", raw_body])
        |> Base.encode16(case: :lower)

      if Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)),
        do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  @doc """
  A signature header for `raw_body` at `timestamp` (Unix seconds) with
  `secret`. Used by tests and the local E2E driver to sign payloads as
  Stripe does; never by request handling.
  """
  @spec sign(binary(), String.t(), integer()) :: String.t()
  def sign(raw_body, secret, timestamp) do
    signature =
      :crypto.mac(:hmac, :sha256, secret, [Integer.to_string(timestamp), ".", raw_body])
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  defp parse(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    timestamps = for [k, v] <- pairs, k == "t", do: v
    signatures = for [k, v] <- pairs, k == "v1", Regex.match?(~r/\A[0-9a-f]{64}\z/, v), do: v

    case {timestamps, signatures} do
      {[t], [_ | _]} ->
        case Integer.parse(t) do
          {timestamp, ""} -> {:ok, timestamp, signatures}
          _ -> {:error, :malformed_signature}
        end

      {_, []} ->
        {:error, :invalid_signature}

      _ ->
        {:error, :malformed_signature}
    end
  end

  defp fresh(timestamp, now, tolerance) do
    if abs(DateTime.to_unix(now) - timestamp) <= tolerance, do: :ok, else: {:error, :expired}
  end
end
