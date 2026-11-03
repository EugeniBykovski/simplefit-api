defmodule Mix.Tasks.Billing.CatalogTest do
  # Not async: switches the Mix shell.
  use SimpleFit.DataCase, async: false

  alias Mix.Tasks.Billing.Catalog, as: Task
  alias SimpleFit.Billing
  alias SimpleFit.Billing.{AuditEvent, Catalog}

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "seeds the provisional catalog as drafts, lists it, and publishes only with approval and confirmation" do
    Task.run(["seed-provisional", "--operator", "ops"])
    assert_received {:mix_shell, :info, ["drafted: starter, growth, pro, enterprise"]}
    assert Billing.published_plans() == []

    Task.run(["list", "starter"])
    assert_received {:mix_shell, :info, [line]}

    assert line =~
             ~r/^starter v1 draft \(provisional\) .* \[month 149\.00 PLN, year 1490\.00 PLN\]$/

    [starter] = Catalog.versions("starter")

    assert_raise Mix.Error, ~r/--approval REF is required/, fn ->
      Task.run(["publish", starter.id, "--operator", "ops"])
    end

    assert_raise Mix.Error, ~r/provisional_confirmation_required/, fn ->
      Task.run(["publish", starter.id, "--approval", "SF-101", "--operator", "ops"])
    end

    assert_raise Mix.Error, ~r/--operator NAME is required/, fn ->
      Task.run(["publish", starter.id, "--approval", "SF-101", "--confirm-provisional"])
    end

    assert Billing.published_plans() == []

    Task.run([
      "publish",
      starter.id,
      "--approval",
      "SF-101",
      "--operator",
      "ops",
      "--confirm-provisional"
    ])

    assert_received {:mix_shell, :info, [published]}
    assert published =~ "starter v1 published"
    assert [%{id: id}] = Billing.published_plans()
    assert id == starter.id

    assert Repo.get_by!(AuditEvent,
             plan_version_id: starter.id,
             event_type: :saas_plan_version_published
           ).actor ==
             "ops"
  end

  test "refuses unknown commands" do
    assert_raise Mix.Error, ~r/usage/, fn -> Task.run(["charge"]) end
  end
end
