defmodule SimpleFit.Observability.SentryFilter do
  @moduledoc """
  What reaches Sentry, and in what form. See ADR 0008.

  **Event policy: unexpected, actionable failures only.**

    * Crashes: exceptions that end a request with 500 (logged by Bandit) or
      crash a process, captured by `Sentry.LoggerHandler`.
    * `Logger.error/2` events: by the logging convention, `:error` means
      someone should look at it (missing provider configuration, unhandled
      context error results). Warnings never reach Sentry.
    * Oban jobs: only when they exhaust their attempts
      (`report_job_error?/2`); transient failures are retried and logged at
      `:warning` by `SimpleFit.Observability.JobLogger`.
    * Expected API errors (`validation_error`, `bad_request`, `unauthorized`,
      `forbidden`, `not_found`, `conflict`, ...) are responses, not failures:
      they are neither logged at `:error` nor raised past Bandit as 5xx, so
      they never become events. Provider failures surfaced as
      `service_unavailable` are logged at `:warning` and are not sent either.

  **Sanitization (`before_send/1`), applied to every event:**

    * no request interface (no headers, cookies, query string, body, env)
      and no user context
    * `extra` reduced to an allow-list; Oban job `args`, `meta` and `tags`
      are dropped
    * stack frames keep module, function, file and line, never `vars`
      (function arguments)
    * secrets in messages and exception values are redacted (bearer tokens,
      `key=value` credentials, presigned-URL signatures, AWS and Resend keys)
  """

  alias Sentry.Interfaces

  @extra_allow_list [:logger_metadata, :id, :worker, :queue, :attempt, :max_attempts]
  @metadata_allow_list [
    :request_id,
    :route,
    :otel_trace_id,
    :otel_span_id,
    :provider,
    :reason,
    :worker,
    :queue,
    :job_id
  ]

  @redactions [
    {~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/i, "\\1 [REDACTED]"},
    {~r/\b(X-Amz-(?:Signature|Credential|Security-Token))=[^&\s"']+/i, "\\1=[REDACTED]"},
    {~r/\b(password|passwd|secret|token|api[_-]?key|access[_-]?key|authorization|code)(["']?\s*[:=]\s*["']?)[^\s&"',}]+/i,
     "\\1\\2[REDACTED]"},
    {~r/\bAKIA[0-9A-Z]{16}\b/, "[REDACTED]"},
    {~r/\bre_[A-Za-z0-9_]{16,}\b/, "[REDACTED]"}
  ]

  @handler_id :sentry_handler

  @doc """
  Adds `Sentry.LoggerHandler` (idempotent). Harmless without a DSN: Sentry
  then sends nothing. Delivery is asynchronous and rate limited, so Sentry
  being slow or down never blocks a request.
  """
  @spec attach_logger_handler() :: :ok
  def attach_logger_handler do
    _ = :logger.remove_handler(@handler_id)

    # At most 10 events per second leave the node, so an error storm cannot
    # flood Sentry or the uplink (disabled in tests for determinism).
    rate_limiting =
      Application.get_env(:simple_fit, :sentry_rate_limiting, max_events: 10, interval: 1_000)

    config =
      %{
        capture_level: :error,
        capture_log_messages: true,
        capture_metadata: @metadata_allow_list,
        tags_from_metadata: [:request_id, :route, :worker]
      }
      |> then(&if(rate_limiting, do: Map.put(&1, :rate_limiting, rate_limiting), else: &1))

    :ok = :logger.add_handler(@handler_id, Sentry.LoggerHandler, %{config: config})
  end

  @doc "Oban integration callback: report a failing job only on its last attempt."
  @spec report_job_error?(module() | nil, Oban.Job.t()) :: boolean()
  def report_job_error?(_worker, %Oban.Job{attempt: attempt, max_attempts: max_attempts}),
    do: attempt >= max_attempts

  @doc "Sentry `:before_send` callback: strips every event to operational data."
  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t()
  def before_send(%Sentry.Event{} = event) do
    %{
      event
      | request: %Interfaces.Request{},
        user: %{},
        extra: sanitize_extra(event.extra),
        message: sanitize_message(event.message),
        exception: Enum.map(event.exception, &sanitize_exception/1),
        breadcrumbs: Enum.map(event.breadcrumbs, &sanitize_breadcrumb/1)
    }
  end

  @doc "Redacts credentials and signatures from free text."
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    Enum.reduce(@redactions, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def redact(other), do: other

  defp sanitize_extra(extra) when is_map(extra) do
    extra
    |> Map.new(fn {key, value} -> {to_atom_key(key), value} end)
    |> Map.take(@extra_allow_list)
    |> Map.update(:logger_metadata, nil, &sanitize_metadata/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp sanitize_extra(_extra), do: %{}

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {to_atom_key(key), value} end)
    |> Map.take(@metadata_allow_list)
  end

  defp sanitize_metadata(_metadata), do: nil

  # Known keys only; unknown string keys stay strings and are dropped.
  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp sanitize_message(%Interfaces.Message{} = message) do
    %{
      message
      | formatted: redact(message.formatted),
        message: redact(message.message),
        params: nil
    }
  end

  defp sanitize_message(message), do: message

  defp sanitize_exception(%Interfaces.Exception{} = exception) do
    %{
      exception
      | value: redact(exception.value),
        stacktrace: sanitize_stacktrace(exception.stacktrace)
    }
  end

  defp sanitize_exception(exception), do: exception

  defp sanitize_stacktrace(%Interfaces.Stacktrace{frames: frames} = stacktrace)
       when is_list(frames) do
    %{stacktrace | frames: Enum.map(frames, &%{&1 | vars: nil})}
  end

  defp sanitize_stacktrace(stacktrace), do: stacktrace

  defp sanitize_breadcrumb(%Interfaces.Breadcrumb{} = breadcrumb),
    do: %{breadcrumb | message: redact(breadcrumb.message), data: nil}

  defp sanitize_breadcrumb(%{} = breadcrumb) do
    breadcrumb
    |> Map.update(:message, nil, &redact/1)
    |> Map.delete(:data)
  end

  defp sanitize_breadcrumb(breadcrumb), do: breadcrumb
end
