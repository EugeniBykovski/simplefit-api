defmodule SimpleFit.RateLimitRaceTest do
  @moduledoc """
  Rolling limits under true concurrency (SF-83, D-G25), on separate database
  connections outside the SQL sandbox, so the advisory lock is exercised for
  real. Rows are committed: the test removes its own bucket's events.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.{RateLimit, Repo}

  @bucket "rolling_race_#{Ecto.UUID.generate()}"

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(e in "rate_limit_events", where: e.bucket == ^@bucket))
      Sandbox.mode(Repo, :manual)
    end)
  end

  test "concurrent hits on one key count exactly: 5 of 16 allowed" do
    key = :crypto.strong_rand_bytes(32)
    now = DateTime.utc_now()

    results =
      for(_ <- 1..16, do: fn -> RateLimit.hit_rolling([{@bucket, key, 5, 86_400}], now) end)
      |> Enum.map(&Task.async/1)
      |> Task.await_many(30_000)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:error, {:rate_limited, _}}, &1)) == 11

    assert Repo.aggregate(
             from(e in "rate_limit_events", where: e.bucket == ^@bucket, select: e.id),
             :count
           ) ==
             5
  end
end
