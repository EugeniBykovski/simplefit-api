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

  test "list and show print the review data; decisions need the revision", ctx do
    id = ctx.view.application.id
    Task.run(["list"])
    assert [line] = lines()
    assert line =~ id
    assert line =~ "revision #{ctx.view.application.revision}"

    Task.run(["show", id])
    shown = Enum.join(lines(), "\n")
    assert shown =~ "Simple Boxing Sp. z o.o."
    assert shown =~ "submitted"
    refute shown =~ "business-verification/"

    assert_raise Mix.Error, ~r/refused: \{:conflict, %\{revision: "stale"\}\}/, fn ->
      Task.run(["approve", id, "--revision", "1"])
    end

    Task.run([
      "approve",
      id,
      "--revision",
      "#{ctx.view.application.revision}"
    ])

    assert [approved] = lines()
    assert approved =~ "#{id}: approved"

    Task.run(["revoke", id, "--reason", "business_closed"])
    assert [revoked] = lines()
    assert revoked =~ "#{id}: revoked"
    assert Repo.get!(VerificationApplication, id).status == :revoked
  end

  test "document-url prints a short-lived link and records the download", ctx do
    [evidence] = ctx.view.evidence
    Task.run(["document-url", ctx.view.application.id, evidence.id])
    assert ["valid until " <> _, url] = lines()
    assert url =~ "method=get"

    assert_raise Mix.Error, ~r/unknown command/, fn -> Task.run(["publish", ctx.gym.id]) end
  end

  test "--operator is gone: no flag names an operator, on any command (SF-136)", ctx do
    id = ctx.view.application.id
    revision = "#{ctx.view.application.revision}"

    for args <- [
          ["list", "--operator", "reviewer@trust.simplefit.test"],
          ["show", id, "--operator", "reviewer@trust.simplefit.test"],
          ["approve", id, "--revision", revision, "--operator", "reviewer@trust.simplefit.test"],
          ["approve", id, "--revision", revision, "--operator-email", "someone@example.com"],
          ["approve", id, "--revision", revision, "--actor-id", Ecto.UUID.generate()],
          ["reject", id, "--revision", revision, "--reason", "other", "--credential", "x"],
          ["revoke", id, "--reason", "other", "--operator", "someone@example.com"]
        ] do
      assert_raise Mix.Error, ~r/operators aren't named on the command line/, fn ->
        Task.run(args)
      end
    end

    assert Repo.get!(VerificationApplication, id).status == :submitted
  end

  test "the history labels what can and can't be believed", ctx do
    id = ctx.view.application.id
    Task.run(["approve", id, "--revision", "#{ctx.view.application.revision}"])
    lines()
    Task.run(["show", id])
    shown = Enum.join(lines(), "\n")

    assert shown =~
             "approved  r#{ctx.view.application.revision}  by local_fixture #{reviewer_actor_id()}"

    refute shown =~ "legacy"
  end
end
