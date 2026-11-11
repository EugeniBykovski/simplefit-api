defmodule SimpleFit.Observability.Operations do
  @moduledoc """
  What an operator can know about the running system (SF-126, AD17), measured, never
  assumed. Every check carries its source, a status and when it was observed; a check
  with nothing to measure says `no_telemetry`, and a measurement that fails says
  `unavailable`, never zero or healthy. Nothing here is an uptime percentage: no
  history is kept to compute one.

  * **Health** (`health/1`): the API (this request was served), the database (a timed
    query), background jobs, email delivery jobs and Stripe webhook events (from the
    database), plus storage and error monitoring, which report nothing to the app
    (`no_telemetry`). Counts per queue and state, applied migrations, and the release
    and environment as configured.
  * **Jobs** (`jobs_page/3`, `job/1`): allowlisted metadata only: id, queue, worker,
    state, attempts and timestamps, and of the last error only the exception module
    (never its message, the arguments, `meta` or a stack trace). Oban prunes finished
    jobs after a day, so history is a day long.

  Statuses (documented per check in `health/1`): `healthy` (measured fine),
  `degraded` (measured, with failures in the window), `unavailable` (the measurement
  itself failed), `unknown` (measured, but the signal can't say), `no_telemetry`
  (nothing is measured). Each check is its own observation; together they aren't one
  atomic snapshot.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.{Observability, Repo}

  @unlogged [log: false]
  @day 86_400
  @states ~w(available scheduled executing retryable completed discarded cancelled)
  @waiting ~w(available scheduled retryable)
  @failed ~w(discarded cancelled)
  # Workers by module name: the only values the job list can filter on.
  @workers ~w(SimpleFit.Accounts.EmailAuth.CleanupWorker SimpleFit.Billing.Stripe.EventWorker
              SimpleFit.Billing.Stripe.SweepWorker SimpleFit.Email.DeliveryWorker
              SimpleFit.Gyms.VerificationCleanupWorker SimpleFit.Sponsors.EvidenceCleanupWorker)
  @mailer "SimpleFit.Email.DeliveryWorker"

  @doc "Oban job states, in lifecycle order."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The workers this application runs (the job list's worker filter)."
  @spec workers() :: [String.t()]
  def workers, do: @workers

  @doc "The configured queues and their concurrency limits."
  @spec queues() :: [%{name: String.t(), limit: pos_integer()}]
  def queues do
    :simple_fit
    |> Application.get_env(Oban, [])
    |> Keyword.get(:queues, [])
    |> Enum.map(fn {name, limit} -> %{name: Atom.to_string(name), limit: queue_limit(limit)} end)
  end

  defp queue_limit(limit) when is_integer(limit), do: limit
  defp queue_limit(opts) when is_list(opts), do: Keyword.get(opts, :limit, 0)

  @doc """
  The health page at `now`. Check statuses:

  * `api` - `healthy`: this request reached the application and is being answered.
  * `database` - `healthy` when a timed `SELECT 1` answers, else `unavailable`.
  * `background_jobs` - `degraded` when any job was discarded or cancelled in the last
    24 hours or is retrying, `healthy` otherwise.
  * `email` - delivery jobs in the last 24 hours: `degraded` when any was discarded or
    cancelled, `healthy` when at least one was accepted by the provider and none
    failed, `unknown` when none ran. Acceptance by the provider isn't delivery.
  * `payments_webhooks` - Stripe events received in the last 24 hours: `degraded` when
    any failed to process, otherwise `unknown` (a receipt time isn't health).
  * `storage`, `error_monitoring` - `no_telemetry`: nothing is reported to the app.

  Any database check that raises is `unavailable`, not zero.
  """
  @spec health(DateTime.t()) :: map()
  def health(%DateTime{} = now) do
    since = DateTime.add(now, -@day, :second)
    {database, jobs} = database_and_jobs(since)

    %{
      observed_at: now,
      checks: [
        %{id: :api, status: :healthy, observed_at: now, counts: [], last_event_at: nil},
        database,
        jobs_check(jobs, now),
        measured(:email, now, fn -> email_check(since, now) end),
        measured(:payments_webhooks, now, fn -> webhook_check(since, now) end),
        %{id: :storage, status: :no_telemetry, observed_at: nil, counts: [], last_event_at: nil},
        %{
          id: :error_monitoring,
          status: :no_telemetry,
          observed_at: nil,
          counts: [],
          last_event_at: nil
        }
      ],
      queues: queue_counts(jobs),
      migrations: measured_value(fn -> migrations() end),
      release: release()
    }
  end

  defp database_and_jobs(since) do
    started = System.monotonic_time()

    case safely(fn -> Repo.query!("SELECT 1", [], @unlogged) end) do
      {:ok, _} ->
        elapsed =
          System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

        now = DateTime.utc_now()

        {%{
           id: :database,
           status: :healthy,
           observed_at: now,
           counts: [query_ms: elapsed],
           last_event_at: nil
         }, unwrap(safely(fn -> job_state_counts(since) end))}

      :error ->
        {%{
           id: :database,
           status: :unavailable,
           observed_at: DateTime.utc_now(),
           counts: [],
           last_event_at: nil
         }, :error}
    end
  end

  # Counts by queue and state; finished states only within the window (Oban prunes
  # them after a day anyway).
  defp job_state_counts(since) do
    from(j in Oban.Job,
      where:
        j.state in ["available", "scheduled", "executing", "retryable"] or j.inserted_at >= ^since,
      group_by: [j.queue, j.state],
      select: {j.queue, j.state, count()}
    )
    |> Repo.all(@unlogged)
  end

  defp jobs_check(:error, now),
    do: %{
      id: :background_jobs,
      status: :unavailable,
      observed_at: now,
      counts: [],
      last_event_at: nil
    }

  defp jobs_check(rows, now) do
    total = fn states ->
      rows |> Enum.filter(&(elem(&1, 1) in states)) |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    end

    waiting = total.(@waiting)
    failed = total.(@failed)
    retrying = total.(["retryable"])

    %{
      id: :background_jobs,
      status: if(failed + retrying > 0, do: :degraded, else: :healthy),
      observed_at: now,
      counts: [waiting: waiting, executing: total.(["executing"]), failed_24h: failed],
      last_event_at: nil
    }
  end

  defp queue_counts(:error), do: :unavailable

  defp queue_counts(rows) do
    Enum.map(queues(), fn %{name: name, limit: limit} ->
      counts =
        Map.new(@states, fn state ->
          {state,
           rows
           |> Enum.filter(&(elem(&1, 0) == name and elem(&1, 1) == state))
           |> Enum.map(&elem(&1, 2))
           |> Enum.sum()}
        end)

      %{name: name, limit: limit, counts: counts}
    end)
  end

  defp email_check(since, now) do
    counts =
      from(j in Oban.Job,
        where: j.worker == @mailer and j.inserted_at >= ^since,
        group_by: j.state,
        select: {j.state, count()}
      )
      |> Repo.all(@unlogged)
      |> Map.new()

    accepted = Map.get(counts, "completed", 0)
    failed = Map.get(counts, "discarded", 0) + Map.get(counts, "cancelled", 0)
    pending = Enum.sum(Enum.map(@waiting ++ ["executing"], &Map.get(counts, &1, 0)))

    status =
      cond do
        failed > 0 -> :degraded
        accepted > 0 -> :healthy
        true -> :unknown
      end

    %{
      id: :email,
      status: status,
      observed_at: now,
      counts: [accepted_24h: accepted, failed_24h: failed, pending: pending],
      last_event_at: nil
    }
  end

  defp webhook_check(since, now) do
    counts = SimpleFit.Billing.webhook_counts(since)
    last = SimpleFit.Billing.last_webhook_received_at()
    failed = Map.get(counts, :failed, 0)

    %{
      id: :payments_webhooks,
      status: if(failed > 0, do: :degraded, else: :unknown),
      observed_at: now,
      counts: [
        received_24h: counts |> Map.values() |> Enum.sum(),
        processed_24h: Map.get(counts, :processed, 0),
        ignored_24h: Map.get(counts, :ignored, 0),
        failed_24h: failed
      ],
      last_event_at: last
    }
  end

  defp measured(id, now, fun) do
    case safely(fun) do
      {:ok, check} -> check
      :error -> %{id: id, status: :unavailable, observed_at: now, counts: [], last_event_at: nil}
    end
  end

  defp measured_value(fun) do
    case safely(fun) do
      {:ok, value} -> value
      :error -> :unavailable
    end
  end

  defp migrations do
    %{rows: [[count, latest]]} =
      Repo.query!("SELECT count(*), max(version) FROM schema_migrations", [], @unlogged)

    %{applied: count, latest_version: latest && Integer.to_string(latest)}
  end

  # The release and environment as configured (SENTRY_RELEASE / SENTRY_ENVIRONMENT);
  # `source: default` when no release was supplied and the app version stands in.
  defp release do
    %{release: release, environment: environment} = Observability.metadata()

    %{
      release: release,
      environment: environment,
      source: if(release == Observability.default_release(), do: :default, else: :configured)
    }
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(:error), do: :error

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    _exception in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] -> :error
  end

  ## Jobs

  @doc """
  One page of jobs, newest first (by id), after `position` (a job id). Filters:
  `:state`, `:queue`, `:worker` (validated by the caller against `states/0`,
  `queues/0`, `workers/0`). Returns `{jobs, next_position | nil}`.
  """
  @spec jobs_page(map(), pos_integer(), pos_integer() | nil) :: {[map()], pos_integer() | nil}
  def jobs_page(filters, limit, position) do
    rows =
      Enum.reduce(filters, Oban.Job, fn
        {:state, state}, q -> from(j in q, where: j.state == ^state)
        {:queue, queue}, q -> from(j in q, where: j.queue == ^queue)
        {:worker, worker}, q -> from(j in q, where: j.worker == ^worker)
      end)
      |> then(fn q -> if position, do: from(j in q, where: j.id < ^position), else: q end)
      |> then(&from(j in &1, order_by: [desc: j.id], limit: ^(limit + 1), select: ^job_fields()))
      |> Repo.all(@unlogged)

    {page, more} = Enum.split(rows, limit)
    next = if more == [], do: nil, else: List.last(page).id
    {Enum.map(page, &job_view/1), next}
  end

  @doc "One job's allowlisted metadata, or `nil`."
  @spec job(pos_integer()) :: map() | nil
  def job(id) do
    case Repo.one(from(j in Oban.Job, where: j.id == ^id, select: ^job_fields()), @unlogged) do
      nil -> nil
      row -> job_view(row)
    end
  end

  # Selected columns only: `args` and `meta` are never read. Of `errors`, only the
  # last entry's text is read here, to take its exception module, and dropped.
  defp job_fields,
    do: [
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
      :errors
    ]

  defp job_view(row) do
    row
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
      :cancelled_at
    ])
    |> Map.merge(%{failure: failure(row.errors), errors: length(row.errors || [])})
  end

  @doc false
  # The exception module of the last error ("** (Module) ..."), or `nil`: never the
  # message, which can carry data.
  @spec failure([map()] | nil) :: String.t() | nil
  def failure(errors) when is_list(errors) and errors != [] do
    with %{"error" => text} when is_binary(text) <- List.last(errors),
         %{"module" => module} <-
           Regex.named_captures(~r/\A\*\* \((?<module>[A-Z][A-Za-z0-9_.]{0,119})\)/, text) do
      module
    else
      _ -> nil
    end
  end

  def failure(_errors), do: nil
end
