defmodule SimpleFit.Email.Templates.Format do
  @moduledoc """
  English display formats used by the email templates (ADR 0011), as the
  Claude Design artboards show them. Localization is future work.
  """

  @doc ~S|"Oct 3": month and day, no year.|
  @spec short_date(Date.t()) :: String.t()
  def short_date(date), do: Calendar.strftime(date, "%b %-d")

  @doc ~S|"Oct 31, 2026".|
  @spec long_date(Date.t()) :: String.t()
  def long_date(date), do: Calendar.strftime(date, "%b %-d, %Y")

  @doc ~S|"Tue, Nov 3".|
  @spec weekday_date(Date.t()) :: String.t()
  def weekday_date(date), do: Calendar.strftime(date, "%a, %b %-d")

  @doc ~S|"1 round", "8 rounds".|
  @spec count(integer(), String.t(), String.t()) :: String.t()
  def count(1, singular, _plural), do: "1 #{singular}"
  def count(n, _singular, plural), do: "#{n} #{plural}"

  @doc ~S|A validated URL shown as text, without its scheme: "sfit.box/c/yauheni".|
  @spec bare_url(String.t()) :: String.t()
  def bare_url(url), do: String.replace(url, ~r{\Ahttps?://}, "")
end
