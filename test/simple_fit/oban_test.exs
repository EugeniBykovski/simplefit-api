defmodule SimpleFit.ObanTest do
  use SimpleFit.DataCase, async: true

  test "Oban is supervised with minimal queues and never runs jobs automatically in test" do
    config = Oban.config()

    assert config.repo == SimpleFit.Repo
    assert config.testing == :manual

    assert Keyword.keys(Application.fetch_env!(:simple_fit, Oban)[:queues]) == [
             :default,
             :mailers
           ]
  end

  test "the oban_jobs table exists (migration applied)" do
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*)::int FROM oban_jobs")
  end
end
