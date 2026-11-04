defmodule Mix.Tasks.Gyms.VerificationTest do
  # Not async: switches the Mix shell.
  use SimpleFit.DataCase, async: false

  import SimpleFit.GymHelpers
  import SimpleFit.VerificationHelpers

  alias Mix.Tasks.Gyms.Verification, as: Task
  alias SimpleFit.Gyms.VerificationApplication
  alias SimpleFit.Repo

  setup do
    Repo.delete_all("rate_limit_events")
    stub_storage(%{})
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    owner = registered!("kyb-task")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, view: submitted!(owner, gym.id)}
  end

  defp lines do
    receive do
      {:mix_shell, :info, [line]} -> [line | lines()]
    after
      0 -> []
    end
  end

  test "list and show print the review data; decisions need an operator and the revision", ctx do
    id = ctx.view.application.id
    Task.run(["list", "--operator", operator()])
    assert [line] = lines()
    assert line =~ id
    assert line =~ "revision #{ctx.view.application.revision}"

    Task.run(["show", id, "--operator", operator()])
    shown = Enum.join(lines(), "\n")
    assert shown =~ "Simple Boxing Sp. z o.o."
    assert shown =~ "submitted"
    refute shown =~ "business-verification/"

    assert_raise Mix.Error, ~r/refused: \{:forbidden, :operator\}/, fn ->
      Task.run(["list", "--operator", "anyone@example.com"])
    end

    assert_raise Mix.Error, ~r/refused: \{:invalid, :operator\}/, fn ->
      Task.run(["approve", id, "--revision", "#{ctx.view.application.revision}"])
    end

    assert_raise Mix.Error, ~r/refused: \{:conflict, %\{revision: "stale"\}\}/, fn ->
      Task.run(["approve", id, "--revision", "1", "--operator", operator()])
    end

    Task.run([
      "approve",
      id,
      "--revision",
      "#{ctx.view.application.revision}",
      "--operator",
      operator()
    ])

    assert [approved] = lines()
    assert approved =~ "#{id}: approved"

    Task.run(["revoke", id, "--reason", "business_closed", "--operator", operator()])
    assert [revoked] = lines()
    assert revoked =~ "#{id}: revoked"
    assert Repo.get!(VerificationApplication, id).status == :revoked
  end

  test "document-url prints a short-lived link and records the download", ctx do
    [evidence] = ctx.view.evidence
    Task.run(["document-url", ctx.view.application.id, evidence.id, "--operator", operator()])
    assert ["valid until " <> _, url] = lines()
    assert url =~ "method=get"

    assert_raise Mix.Error, ~r/unknown command/, fn -> Task.run(["publish", ctx.gym.id]) end
  end
end
