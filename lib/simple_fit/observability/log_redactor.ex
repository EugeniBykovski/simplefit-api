defmodule SimpleFit.Observability.LogRedactor do
  @moduledoc """
  A primary `:logger` filter that redacts every log event's text (SF-29,
  ADR 0019), whatever logged it: SimpleFit code, Phoenix, Bandit, Ecto,
  Oban or an OTP crash report.

  Logs are structured and carry allow-listed metadata only, so credentials
  should never be in them. This filter covers what nobody wrote on purpose:
  the message of an unexpected exception, a crash report with a process
  state, a library's error text. It runs after Elixir's translator (it is
  added after it), so OTP crash reports arrive as text with their
  `crash_reason`, which Sentry's handler still receives; the exception
  message inside `crash_reason` is redacted too, keeping the exception type.

  Text is redacted with `SimpleFit.Observability.Redaction`. A filter that
  raises is removed by `:logger`, so this one never raises: on any internal
  error the event keeps its level and metadata (so it still counts and still
  reaches Sentry) but its text is replaced, never passed through unredacted.
  """

  alias SimpleFit.Observability.Redaction

  @filter_id :simplefit_redact

  @doc "Adds the filter as the last primary filter (idempotent)."
  @spec attach() :: :ok
  def attach do
    _ = :logger.remove_primary_filter(@filter_id)
    :ok = :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []})
  end

  @doc false
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(%{msg: msg, meta: meta} = event, _config) do
    %{event | msg: redact_msg(msg, meta), meta: redact_meta(meta)}
  rescue
    _error -> %{event | msg: {:string, "log message withheld: redaction failed"}}
  end

  defp redact_msg({:string, chardata}, _meta),
    do: {:string, Redaction.redact(IO.chardata_to_string(chardata))}

  defp redact_msg({:format, format, args}, _meta),
    do: {:string, format |> :io_lib.format(args) |> IO.chardata_to_string() |> Redaction.redact()}

  defp redact_msg({:report, report}, meta),
    do: {:string, report |> report_text(meta) |> Redaction.redact()}

  defp redact_msg(other, _meta), do: other

  defp report_text(report, %{report_cb: callback}) when is_function(callback, 1) do
    {format, args} = callback.(report)
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp report_text(report, %{report_cb: callback}) when is_function(callback, 2),
    do:
      report
      |> callback.(%{depth: :unlimited, chars_limit: :unlimited, single_line: false})
      |> IO.chardata_to_string()

  defp report_text(report, _meta) do
    {format, args} = :logger.format_report(report)
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp redact_meta(%{crash_reason: {%{message: message} = exception, stacktrace}} = meta)
       when is_binary(message),
       do: %{meta | crash_reason: {%{exception | message: Redaction.redact(message)}, stacktrace}}

  defp redact_meta(meta), do: meta
end
