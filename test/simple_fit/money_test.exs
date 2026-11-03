defmodule SimpleFit.MoneyTest do
  @moduledoc "Money as integer minor units and decimal strings (SF-101): no float ever."

  use ExUnit.Case, async: true

  alias SimpleFit.Money

  test "parses decimal strings and Decimals into minor units by the currency's exponent" do
    assert Money.parse("149", "PLN") == {:ok, 14_900}
    assert Money.parse("149.00", "PLN") == {:ok, 14_900}
    assert Money.parse("169.5", "PLN") == {:ok, 16_950}
    assert Money.parse("0", "EUR") == {:ok, 0}
    assert Money.parse("0.01", "USD") == {:ok, 1}
    assert Money.parse("1490", "JPY") == {:ok, 1490}
    assert Money.parse(Decimal.new("349.99"), "PLN") == {:ok, 34_999}
    assert Money.parse("149.000000", "PLN") == {:ok, 14_900}
  end

  test "refuses floats, integers, negatives, excess precision, bad formats and unknown currencies" do
    assert Money.parse(149.0, "PLN") == {:error, :invalid_type}
    assert Money.parse(149, "PLN") == {:error, :invalid_type}
    assert Money.parse(nil, "PLN") == {:error, :invalid_type}
    assert Money.parse("-1", "PLN") == {:error, :negative}
    assert Money.parse(Decimal.new("-0.01"), "PLN") == {:error, :negative}
    assert Money.parse("0.001", "PLN") == {:error, :too_precise}
    assert Money.parse("1.5", "JPY") == {:error, :too_precise}
    assert Money.parse("1e3", "PLN") == {:error, :invalid_format}
    assert Money.parse("1,50", "PLN") == {:error, :invalid_format}
    assert Money.parse(" 1", "PLN") == {:error, :invalid_format}
    assert Money.parse("NaN", "PLN") == {:error, :invalid_format}
    assert Money.parse("10", "XYZ") == {:error, :invalid_currency}
    assert Money.parse("10", "pln") == {:error, :invalid_currency}
    assert Money.parse("9999999999999", "PLN") == {:error, :out_of_range}
  end

  test "formats minor units as decimal strings and compares only within a currency" do
    assert Money.format(14_900, "PLN") == "149.00"
    assert Money.format(1, "EUR") == "0.01"
    assert Money.format(0, "PLN") == "0.00"
    assert Money.format(1490, "JPY") == "1490"
    assert Money.equal?(%{currency: "PLN", amount_minor: 1}, %{currency: "PLN", amount_minor: 1})
    refute Money.equal?(%{currency: "PLN", amount_minor: 1}, %{currency: "EUR", amount_minor: 1})
    assert "PLN" in Money.currencies()
    refute Money.currency?("XYZ")
  end
end
