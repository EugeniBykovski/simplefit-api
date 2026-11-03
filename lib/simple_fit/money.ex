defmodule SimpleFit.Money do
  @moduledoc """
  Money in SimpleFit (SF-101): an amount in integer minor units of one ISO
  4217 currency the application supports. Never a float.

  * A decimal amount is accepted only as a string or a `Decimal` (never a
    JSON number, which a client may already have rounded through a float),
    must be non-negative and may not be finer than the currency's minor
    unit: `"149.00"` and `"149"` are 14900 grosze, `"149.005"` is refused
    rather than rounded or truncated.
  * Amounts of different currencies are never compared, added or converted:
    `149.00 PLN` is not `149.00 EUR`.
  * No VAT, rounding mode, discount or conversion is applied anywhere: a
    price is stored and shown exactly as it was entered.
  """

  # ISO 4217 code => minor unit exponent.
  @currencies %{
    "PLN" => 2,
    "EUR" => 2,
    "USD" => 2,
    "GBP" => 2,
    "CHF" => 2,
    "CZK" => 2,
    "SEK" => 2,
    "NOK" => 2,
    "DKK" => 2,
    "HUF" => 2,
    "UAH" => 2,
    "JPY" => 0
  }

  # 10^12 minor units: far above any price, far below a 64-bit overflow.
  @max_minor 1_000_000_000_000

  @type t :: %{amount_minor: non_neg_integer(), currency: String.t()}

  @doc "The supported ISO 4217 currency codes, sorted."
  @spec currencies() :: [String.t()]
  def currencies, do: @currencies |> Map.keys() |> Enum.sort()

  @doc "Whether `code` is a supported currency (exact upper-case ISO code)."
  @spec currency?(term()) :: boolean()
  def currency?(code), do: is_binary(code) and Map.has_key?(@currencies, code)

  @doc "The minor unit exponent of a supported currency (PLN 2, JPY 0)."
  @spec exponent(String.t()) :: non_neg_integer()
  def exponent(currency), do: Map.fetch!(@currencies, currency)

  @doc """
  Parses a decimal amount in `currency` into minor units.

  Errors: `:invalid_currency`, `:invalid_type` (not a string or `Decimal`),
  `:invalid_format`, `:negative`, `:too_precise` (finer than the minor
  unit), `:out_of_range`.
  """
  @spec parse(term(), term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def parse(amount, currency) do
    with :ok <- check_currency(currency),
         {:ok, decimal} <- decimal(amount),
         :ok <- non_negative(decimal),
         {:ok, minor} <- to_minor(decimal, exponent(currency)) do
      if minor <= @max_minor, do: {:ok, minor}, else: {:error, :out_of_range}
    end
  end

  @doc "The decimal string of `minor` units in `currency`: 14900 PLN is `\"149.00\"`."
  @spec format(non_neg_integer(), String.t()) :: String.t()
  def format(minor, currency) when is_integer(minor) and minor >= 0 do
    minor
    |> Decimal.new()
    |> Decimal.div(Decimal.new(10 ** exponent(currency)))
    |> Decimal.round(exponent(currency))
    |> Decimal.to_string(:normal)
  end

  @doc "Exact equality: the same currency and the same minor units."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%{currency: currency, amount_minor: a}, %{currency: currency, amount_minor: b}),
    do: a == b

  def equal?(%{}, %{}), do: false

  defp check_currency(currency),
    do: if(currency?(currency), do: :ok, else: {:error, :invalid_currency})

  defp decimal(%Decimal{} = decimal), do: finite(decimal)

  defp decimal(amount) when is_binary(amount) do
    cond do
      String.match?(amount, ~r/\A\d{1,13}(\.\d{1,6})?\z/) -> finite(Decimal.new(amount))
      String.match?(amount, ~r/\A-\d{1,13}(\.\d{1,6})?\z/) -> {:error, :negative}
      true -> {:error, :invalid_format}
    end
  end

  defp decimal(_), do: {:error, :invalid_type}

  defp finite(%Decimal{coef: coef}) when coef in [:inf, :NaN], do: {:error, :invalid_format}
  defp finite(%Decimal{} = decimal), do: {:ok, decimal}

  defp non_negative(decimal),
    do: if(Decimal.negative?(decimal), do: {:error, :negative}, else: :ok)

  # Exact: the amount times 10^exponent must be a whole number.
  defp to_minor(decimal, exponent) do
    scaled = Decimal.mult(decimal, Decimal.new(10 ** exponent))

    if Decimal.equal?(scaled, Decimal.round(scaled, 0, :down)),
      do: {:ok, scaled |> Decimal.round(0) |> Decimal.to_integer()},
      else: {:error, :too_precise}
  end
end
