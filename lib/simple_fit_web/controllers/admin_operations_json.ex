defmodule SimpleFitWeb.AdminOperationsJSON do
  @moduledoc "Renders the operator operations views (SF-126): allowlisted fields only."

  def health(%{health: health}) do
    %{
      health: %{
        observed_at: health.observed_at,
        checks: Enum.map(health.checks, &check/1),
        queues: if(health.queues == :unavailable, do: nil, else: health.queues),
        migrations: if(health.migrations == :unavailable, do: nil, else: health.migrations),
        release: health.release
      }
    }
  end

  def jobs(%{page: page}), do: %{jobs: Enum.map(page.jobs, &job/1), next_cursor: page.next_cursor}

  def show(%{job: job}), do: %{job: job(job)}

  defp check(check) do
    %{
      id: check.id,
      status: check.status,
      observed_at: check.observed_at,
      counts: Enum.map(check.counts, fn {key, value} -> %{key: key, value: value} end),
      last_event_at: check.last_event_at
    }
  end

  defp job(job) do
    job
    |> Map.take([
      :id,
      :queue,
      :worker,
      :state,
      :attempt,
      :max_attempts,
      :inserted_at,
      :scheduled_at,
      :attempted_at,
      :completed_at,
      :discarded_at,
      :cancelled_at,
      :failure,
      :errors
    ])
    |> Map.put(:retry, "not_supported")
  end
end
