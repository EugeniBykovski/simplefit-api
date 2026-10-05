defmodule SimpleFit.Observability.ProviderTracing do
  @moduledoc """
  OpenTelemetry spans for the SF-15 provider boundaries, from their existing
  `:telemetry` spans (`[:simple_fit, :email, :deliver]`,
  `[:simple_fit, :storage, :presign]`).

  Each span (`provider email.deliver`, `provider storage.presign`) carries
  only the capability, the adapter (`Resend`, `S3`, `Fake`, ...), the storage
  method and the normalized result: `ok` or a `SimpleFit.Provider` reason.
  Messages, object keys, URLs and credentials never reach a span. Outbound
  HTTP made inside the boundary appears as a child span from
  `OpentelemetryReq` (see `SimpleFit.HTTP`).

  The provider vocabulary is recorded for diagnosis only; it never changes
  API semantics (see `SimpleFitWeb.FallbackController`).
  """

  @tracer_id __MODULE__

  @boundaries %{
    [:simple_fit, :email, :deliver] => "email.deliver",
    [:simple_fit, :storage, :presign] => "storage.presign"
  }

  @doc "Attaches the telemetry handlers (idempotent)."
  @spec attach() :: :ok
  def attach do
    events =
      for prefix <- Map.keys(@boundaries), suffix <- [:start, :stop, :exception] do
        prefix ++ [suffix]
      end

    _ = :telemetry.detach(@tracer_id)
    :ok = :telemetry.attach_many(@tracer_id, events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(event, _measurements, metadata, _config) do
    {prefix, [suffix]} = Enum.split(event, 3)
    handle(suffix, Map.fetch!(@boundaries, prefix), metadata)
  end

  defp handle(:start, operation, metadata) do
    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "provider #{operation}", metadata, %{
      kind: :internal,
      attributes: %{
        "simple_fit.provider.operation": operation,
        "simple_fit.provider.adapter": adapter_name(metadata[:adapter])
      }
    })
  end

  defp handle(:stop, _operation, metadata) do
    _ = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)
    result = metadata[:result]

    attributes =
      %{"simple_fit.provider.result": result}
      |> maybe_put(:"simple_fit.provider.method", metadata[:method])

    OpenTelemetry.Tracer.set_attributes(attributes)

    if result != :ok do
      OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, Atom.to_string(result)))
    end

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  defp handle(:exception, _operation, metadata) do
    _ = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)
    # The exception type only: messages can carry provider or user data.
    type = metadata[:reason] |> exception_type() |> inspect()
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, type))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  defp adapter_name(adapter) when is_atom(adapter),
    do: adapter |> Module.split() |> List.last()

  defp adapter_name(_adapter), do: "unknown"

  defp exception_type(%{__struct__: module}), do: module
  defp exception_type(_reason), do: :error

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
