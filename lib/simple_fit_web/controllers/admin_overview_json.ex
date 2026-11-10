defmodule SimpleFitWeb.AdminOverviewJSON do
  @moduledoc "Renders the Control Plane overview (SF-121): counts and check results only."

  def show(%{overview: overview}) do
    %{
      overview: %{
        as_of: overview.as_of,
        period: Map.take(overview.period, [:key, :from, :to]),
        metrics: Enum.map(overview.metrics, &metric/1),
        health: %{
          state: overview.health.state,
          checks: Enum.map(overview.health.checks, &check/1)
        }
      }
    }
  end

  defp metric(metric) do
    %{
      id: metric.id,
      group: metric.group,
      state: metric.state,
      value: metric.value,
      breakdown: counts(metric.breakdown),
      period_counts: counts(metric.period_counts)
    }
  end

  defp check(check) do
    %{
      id: check.id,
      status: check.status,
      counts: counts(check.counts),
      last_event_at: check.last_event_at
    }
  end

  defp counts(list), do: Enum.map(list, fn {key, value} -> %{key: key, value: value} end)
end
