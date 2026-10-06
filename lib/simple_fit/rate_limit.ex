defmodule SimpleFit.RateLimit do
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

  @doc "Deletes windows that started before `cutoff`. Returns the number removed."
  @spec delete_stale(DateTime.t()) :: non_neg_integer()
  def delete_stale(cutoff) do
    %{num_rows: count} =
      Repo.query!(
        "DELETE FROM auth_rate_limits WHERE window_start < $1",
        [DateTime.to_naive(cutoff)],
        log: false
      )

    count
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
