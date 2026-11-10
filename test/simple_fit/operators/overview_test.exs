defmodule SimpleFit.Operators.OverviewTest do
  @moduledoc """
  SF-121: the overview projection at a fixed `now` - period boundaries (start
  inclusive, end exclusive, UTC), the rounding of `as_of`, and that a restricted
  section isn't queried at all.
  """

  use SimpleFit.DataCase, async: true

  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.Accounts.AccountProfile
  alias SimpleFit.Operators.Overview

  @dashboard MapSet.new(["platform.dashboard.read"])

  defp accounts(overview), do: Enum.find(overview.metrics, &(&1.id == :accounts))
  defp in_period(overview), do: accounts(overview).period_counts[:registration_completed]

  # When `user`'s registration completed (stored to the second).
  defp completed_at(user),
    do: Repo.get_by!(AccountProfile, user_id: user.id).registration_completed_at

  test "a record exactly at the start is in the period; exactly at the end, it isn't" do
    t = completed_at(registered!("boundary"))

    # Period [t, t + 24h): starts exactly at t.
    assert in_period(Overview.build(@dashboard, "24h", DateTime.add(t, 86_400, :second))) == 1
    # Period [t + 1s, ...): starts after t.
    assert in_period(Overview.build(@dashboard, "24h", DateTime.add(t, 86_401, :second))) == 0
    # Period [..., t): ends exactly at t.
    assert in_period(Overview.build(@dashboard, "24h", t)) == 0
    # Totals don't depend on the period.
    assert accounts(Overview.build(@dashboard, "24h", t)).value == 1
  end

  test "as_of is now rounded up to the second; the period ends there and spans exactly its length" do
    now = ~U[2026-11-10 12:00:00.250000Z]
    overview = Overview.build(@dashboard, "30d", now)

    assert overview.as_of == ~U[2026-11-10 12:00:01Z]

    assert overview.period == %{
             key: "30d",
             from: ~U[2026-10-11 12:00:01Z],
             to: ~U[2026-11-10 12:00:01Z]
           }

    assert Overview.build(@dashboard, "7d", ~U[2026-11-10 12:00:00Z]).as_of ==
             ~U[2026-11-10 12:00:00Z]
  end

  test "a record in the current second is counted in the total and in the period alike" do
    t = completed_at(registered!("now"))
    overview = Overview.build(@dashboard, "24h", DateTime.add(t, 500_000, :microsecond))
    assert accounts(overview).value == 1
    assert in_period(overview) == 1
  end

  test "period validation: only 24h, 7d and 30d; absent means 7d; empty or unknown is refused" do
    assert {:ok, "7d"} = Overview.period(%{})
    assert {:ok, "24h"} = Overview.period(%{"period" => "24h"})
    assert {:ok, "30d"} = Overview.period(%{"period" => "30d"})

    for bad <- ["", "1y", "7D", " 7d", "-7d", "7d;drop table users"] do
      assert {:error, %Ecto.Changeset{}} = Overview.period(%{"period" => bad})
    end
  end

  test "without a permission nothing of its section is computed or returned" do
    registered!("someone")
    overview = Overview.build(MapSet.new(), "7d", DateTime.utc_now())

    assert Enum.all?(
             overview.metrics,
             &(&1.value == nil and &1.state in [:restricted, :unavailable])
           )

    assert overview.health == %{state: :restricted, checks: []}
  end
end
