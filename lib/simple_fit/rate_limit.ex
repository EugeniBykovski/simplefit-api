defmodule SimpleFit.RateLimit do
  # The cleanup job keeps rows for two days (EmailAuth.CleanupWorker).
  @max_rolling_period 86_400

  @moduledoc """
  Fixed-window rate limits stored in PostgreSQL (ADR 0012).

  Every app instance shares the same counters, so a limit holds however many
  instances run; no Redis or other store is needed. Each hit is one atomic
  upsert:

      INSERT ... ON CONFLICT (bucket, key_digest) DO UPDATE
        SET count = CASE WHEN window_start = new window THEN count + 1 ELSE 1 END
      RETURNING count

  so concurrent hits are counted exactly, never read-then-written. Keys are
  digests computed by the caller (e.g. an HMAC of an email or IP address):
  nothing personal is stored. Hits over the limit are counted too, so a
  client that keeps trying stays limited until the window ends.

  Stale windows are removed by `delete_stale/1` from the hourly cleanup job.

  ## Rolling windows

  `hit_rolling/2` enforces "at most `limit` events in any `period` seconds"
  exactly (D-G25, SF-83), instead of per fixed window. Each counted event is
  one `rate_limit_events` row (bucket, key digest, time). A hit takes a
  transaction-scoped advisory lock on its bucket and key, counts the rows of
  the last `period` seconds and, under the limit, records one more, so
  concurrent hits on one key are counted exactly. A hit over the limit is
  refused and **not** recorded: the window frees up as the oldest counted
  event ages out. All rules of one call commit or roll back together with the
  caller's transaction, so an event counts only if the caller's work commits.
  Periods are at most `#{@max_rolling_period}` seconds: `delete_stale/1`
  removes older events with the windows.
  """

  alias SimpleFit.Repo

  @typedoc "A limit: at most `limit` hits per `period` seconds."
  @type rule ::
          {bucket :: String.t(), key_digest :: binary(), limit :: pos_integer(),
           period :: pos_integer()}

  @doc """
  Records one hit for each rule, in order, and stops at the first rule over
  its limit. Returns `:ok`, or `{:error, {:rate_limited, retry_after}}` with
  the seconds until that window ends.
  """
  @spec hit([rule()], DateTime.t()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def hit(rules, now \\ DateTime.utc_now()) do
    Enum.reduce_while(rules, :ok, fn {bucket, key, limit, period}, :ok ->
      {count, window_start} = increment(bucket, key, period, now)

      if count > limit do
        retry_after = max(DateTime.diff(DateTime.add(window_start, period), now), 1)
        {:halt, {:error, {:rate_limited, retry_after}}}
      else
        {:cont, :ok}
      end
    end)
  end

  @doc """
  Records one event for each rolling rule, in order, inside the caller's
  transaction (or a new one), and stops at the first rule already at its
  limit. Returns `:ok`, or `{:error, {:rate_limited, retry_after}}` with the
  seconds until the oldest counted event of that rule leaves the window.
  On an error nothing of this call is recorded.
  """
  @spec hit_rolling([rule()], DateTime.t()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def hit_rolling(rules, now \\ DateTime.utc_now()) do
    Enum.each(rules, &check_rolling_period!/1)

    if Repo.in_transaction?(),
      do: rolling(rules, now),
      else: rolling_in_transaction(rules, now)
  end

  @doc "Deletes windows and rolling events older than `cutoff`. Returns the number removed."
  @spec delete_stale(DateTime.t()) :: non_neg_integer()
  def delete_stale(cutoff) do
    %{num_rows: windows} =
      Repo.query!(
        "DELETE FROM auth_rate_limits WHERE window_start < $1",
        [DateTime.to_naive(cutoff)],
        log: false
      )

    %{num_rows: events} =
      Repo.query!(
        "DELETE FROM rate_limit_events WHERE occurred_at < $1",
        [DateTime.to_naive(cutoff)],
        log: false
      )

    windows + events
  end

  defp check_rolling_period!({_bucket, _key, _limit, period}) when period <= @max_rolling_period,
    do: :ok

  defp check_rolling_period!(_rule),
    do: raise(ArgumentError, "rolling periods are at most #{@max_rolling_period} seconds")

  defp rolling_in_transaction(rules, now) do
    Repo.transaction(fn ->
      case rolling(rules, now) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Under the caller's transaction: a rule over its limit rolls back every
  # event this call recorded (the caller rolls back on the error).
  defp rolling(rules, now) do
    Enum.reduce_while(rules, :ok, fn {bucket, key, limit, period}, :ok ->
      case rolling_hit(bucket, key, limit, period, now) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp rolling_hit(bucket, key, limit, period, now) do
    since = DateTime.add(now, -period)

    # The lock is its own statement: under READ COMMITTED the count below
    # then takes its snapshot after the lock is granted, so it sees every
    # event committed by the previous holder. (A lock inside the counting
    # statement would count against a snapshot taken before the wait.)
    %{num_rows: 1} =
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1 || ':' || encode($2, 'hex'), 0))",
        [bucket, key],
        # The key digest must not reach the debug query log.
        log: false
      )

    %{rows: [[count, oldest]]} =
      Repo.query!(
        """
        SELECT count(*), min(occurred_at) FROM rate_limit_events
        WHERE bucket = $1 AND key_digest = $2 AND occurred_at > $3
        """,
        [bucket, key, DateTime.to_naive(since)],
        log: false
      )

    if count >= limit do
      oldest = DateTime.from_naive!(oldest, "Etc/UTC")
      {:error, {:rate_limited, max(DateTime.diff(DateTime.add(oldest, period), now), 1)}}
    else
      %{num_rows: 1} =
        Repo.query!(
          "INSERT INTO rate_limit_events (id, bucket, key_digest, occurred_at) VALUES ($1, $2, $3, $4)",
          [Ecto.UUID.bingenerate(), bucket, key, DateTime.to_naive(now)],
          log: false
        )

      :ok
    end
  end

  defp increment(bucket, key, period, now) do
    window_start =
      now
      |> DateTime.to_unix()
      |> div(period)
      |> Kernel.*(period)
      |> DateTime.from_unix!()
      |> DateTime.to_naive()

    %{rows: [[count, stored_start]]} =
      Repo.query!(
        """
        INSERT INTO auth_rate_limits AS l (bucket, key_digest, window_start, count)
        VALUES ($1, $2, $3, 1)
        ON CONFLICT (bucket, key_digest) DO UPDATE
          SET count = CASE WHEN l.window_start = EXCLUDED.window_start THEN l.count + 1 ELSE 1 END,
              window_start = EXCLUDED.window_start
        RETURNING count, window_start
        """,
        [bucket, key, window_start],
        # The key digest must not reach the debug query log.
        log: false
      )

    {count, DateTime.from_naive!(stored_start, "Etc/UTC")}
  end
end
