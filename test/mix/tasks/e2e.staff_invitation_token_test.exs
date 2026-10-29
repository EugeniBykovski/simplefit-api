defmodule Mix.Tasks.E2e.StaffInvitationTokenTest do
  # Not async: switches the Mix shell.
  use SimpleFit.DataCase, async: false

  import SimpleFit.GymHelpers

  alias Mix.Tasks.E2e.StaffInvitationToken

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    owner = registered!("e2e-token")
    %{owner: owner, gym: completed_gym!(owner)}
  end

  test "prints only the latest staff invitation token queued to the address", ctx do
    invite!(ctx.owner, ctx.gym.id, "e2e-staff@example.com", :coach)
    invite!(ctx.owner, ctx.gym.id, "other-staff@example.com", :coach)
    expected = staff_token_for("e2e-staff@example.com")

    StaffInvitationToken.run(["E2E-Staff@example.com"])

    assert_received {:mix_shell, :info, [^expected]}
    refute_received {:mix_shell, :info, _}
  end

  test "fails when no staff invitation was sent to the address" do
    assert_raise Mix.Error, ~r/no staff invitation queued/, fn ->
      StaffInvitationToken.run(["nobody@example.com"])
    end
  end

  test "refuses to run where the end-to-end tools are not enabled (prod)", ctx do
    invite!(ctx.owner, ctx.gym.id, "e2e-staff@example.com", :coach)
    Application.put_env(:simple_fit, :e2e_tools, enabled: false)
    on_exit(fn -> Application.put_env(:simple_fit, :e2e_tools, enabled: true) end)

    assert_raise Mix.Error, ~r/only where :e2e_tools is enabled/, fn ->
      StaffInvitationToken.run(["e2e-staff@example.com"])
    end

    refute_received {:mix_shell, :info, _}
  end

  test "requires exactly one address" do
    assert_raise Mix.Error, ~r/usage/, fn -> StaffInvitationToken.run([]) end
  end
end
