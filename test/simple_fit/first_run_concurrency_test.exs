defmodule SimpleFit.FirstRunConcurrencyTest do
  # The tasks share the test's sandbox connection, which needs shared mode:
  # not async.
  use SimpleFit.DataCase, async: false

  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.FirstRun
  alias SimpleFit.FirstRun.Outcome
  alias SimpleFit.Repo

  test "concurrent outcomes from several tabs record one, and every request sees it" do
    {:ok, user} =
      Accounts.register_user(:google, "first-run-race-#{System.unique_integer([:positive])}")

    complete_fighter_onboarding!(user)

    results =
      1..8
      |> Enum.map(fn i ->
        outcome = if rem(i, 2) == 0, do: "completed", else: "dismissed"

        Task.async(fn ->
          FirstRun.record_outcome(user, "fighter_web_tour", %{"outcome" => outcome})
        end)
      end)
      |> Task.await_many()

    assert [{:ok, kept}] = Enum.uniq(results)
    assert kept.status in [:completed, :dismissed]
    assert Repo.aggregate(Outcome, :count) == 1
  end
end
