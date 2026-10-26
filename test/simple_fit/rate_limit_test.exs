defmodule SimpleFit.RateLimitTest do
  use SimpleFit.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.RateLimit

  @key :crypto.strong_rand_bytes(32)
  @t0 ~U[2026-10-07 12:00:00Z]

  defp hit(limit, period, at), do: RateLimit.hit([{"test_bucket", @key, limit, period}], at)

  test "allows up to the limit within a window, then reports the seconds left" do
    assert :ok = hit(2, 60, @t0)
    assert :ok = hit(2, 60, DateTime.add(@t0, 10))
    assert {:error, {:rate_limited, 30}} = hit(2, 60, DateTime.add(@t0, 30))
  end

  test "a new window starts from zero (minute, hour and day windows)" do
    for period <- [60, 3_600, 86_400] do
      bucket = "window_#{period}"
      rule = fn -> [{bucket, @key, 1, period}] end

      # Windows are aligned to the period (midnight UTC for days).
      start = DateTime.from_unix!(div(DateTime.to_unix(@t0), period) * period)

      assert :ok = RateLimit.hit(rule.(), start)

      assert {:error, {:rate_limited, 1}} =
               RateLimit.hit(rule.(), DateTime.add(start, period - 1))

      assert :ok = RateLimit.hit(rule.(), DateTime.add(start, period))
    end
  end

  test "rules are checked in order and stop at the first limited one" do
    first = {"first", @key, 1, 60}
    second = {"second", @key, 1, 60}

    assert :ok = RateLimit.hit([first, second], @t0)
    assert {:error, {:rate_limited, _}} = RateLimit.hit([first, second], @t0)

    # "second" was not counted by the limited call.
    %{rows: [[count]]} =
      Repo.query!("SELECT count FROM auth_rate_limits WHERE bucket = 'second'", [])

    assert count == 1
  end

  test "stale windows are deleted" do
    hit(5, 60, @t0)
    assert RateLimit.delete_stale(DateTime.add(@t0, 1)) == 1
    assert RateLimit.delete_stale(DateTime.add(@t0, 1)) == 0
  end

  describe "hit_rolling/2 (exact rolling windows, D-G25)" do
    defp roll(limit, at, bucket \\ "rolling_bucket"),
      do: RateLimit.hit_rolling([{bucket, @key, limit, 86_400}], at)

    defp events(bucket \\ "rolling_bucket") do
      Repo.aggregate(
        from(e in "rate_limit_events", where: e.bucket == ^bucket, select: e.id),
        :count
      )
    end

    test "allows the limit in any 24 hours and reports when the oldest event leaves" do
      for minutes <- 0..4, do: assert(:ok = roll(5, DateTime.add(@t0, minutes * 60)))

      # The 6th, an hour later, waits for the first event (t0) to age out.
      assert {:error, {:rate_limited, retry_after}} = roll(5, DateTime.add(@t0, 3_600))
      assert retry_after == 86_400 - 3_600
      assert events() == 5
    end

    test "a burst across a calendar boundary is refused (unlike a fixed window)" do
      before_midnight = ~U[2026-10-07 23:59:00Z]
      for s <- 0..4, do: assert(:ok = roll(5, DateTime.add(before_midnight, s)))

      assert {:error, {:rate_limited, _}} = roll(5, ~U[2026-10-08 00:01:00Z])
    end

    test "the window frees up exactly as events age out; refused hits are not recorded" do
      for s <- 0..4, do: :ok = roll(5, DateTime.add(@t0, s))

      for _ <- 1..10,
          do: {:error, {:rate_limited, 1}} = roll(5, DateTime.add(@t0, 86_399))

      assert events() == 5
      # The window is (now - 24 h, now]: exactly 24 h after the first event it
      # has left; the second (t0 + 1 s) has not.
      assert :ok = roll(5, DateTime.add(@t0, 86_400))
      assert {:error, {:rate_limited, 1}} = roll(5, DateTime.add(@t0, 86_400))
    end

    test "rules commit together: a refused second rule records nothing" do
      other = :crypto.strong_rand_bytes(32)
      :ok = RateLimit.hit_rolling([{"rule_b", other, 1, 86_400}], @t0)

      assert {:error, {:rate_limited, _}} =
               RateLimit.hit_rolling(
                 [{"rule_a", @key, 5, 86_400}, {"rule_b", other, 1, 86_400}],
                 DateTime.add(@t0, 1)
               )

      assert events("rule_a") == 0
    end

    test "periods longer than the cleanup retention are refused" do
      assert_raise ArgumentError, fn ->
        RateLimit.hit_rolling([{"too_long", @key, 1, 86_401}], @t0)
      end
    end

    test "stale events are deleted with the windows" do
      :ok = roll(5, @t0)
      assert RateLimit.delete_stale(DateTime.add(@t0, 1)) == 1
      assert events() == 0
    end
  end
end
