defmodule SimpleFit.RateLimitTest do
  use SimpleFit.DataCase, async: true

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
end
