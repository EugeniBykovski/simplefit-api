defmodule Mix.Tasks.E2e.MemberInvitationTokenTest do
  # Not async: switches the Mix shell.
  use SimpleFit.DataCase, async: false

  import SimpleFit.GymHelpers

  alias Mix.Tasks.E2e.MemberInvitationToken

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    owner = registered!("e2e-member-token")
    %{owner: owner, gym: completed_gym!(owner)}
  end

  test "prints only the latest member invitation token queued to the address", ctx do
    invite_member!(ctx.owner, ctx.gym.id, "e2e-member@example.com")
    invite_member!(ctx.owner, ctx.gym.id, "other-member@example.com")
    expected = member_token_for("e2e-member@example.com")

    MemberInvitationToken.run(["E2E-Member@example.com"])

    assert_received {:mix_shell, :info, [^expected]}
    refute_received {:mix_shell, :info, _}
  end

  test "fails when no member invitation was sent to the address" do
    assert_raise Mix.Error, ~r/no member invitation queued/, fn ->
      MemberInvitationToken.run(["nobody@example.com"])
    end
  end

  test "refuses to run where the end-to-end tools are not enabled (prod)", ctx do
    invite_member!(ctx.owner, ctx.gym.id, "e2e-member@example.com")
    Application.put_env(:simple_fit, :e2e_tools, enabled: false)
    on_exit(fn -> Application.put_env(:simple_fit, :e2e_tools, enabled: true) end)

    assert_raise Mix.Error, ~r/only where :e2e_tools is enabled/, fn ->
      MemberInvitationToken.run(["e2e-member@example.com"])
    end

    refute_received {:mix_shell, :info, _}
  end

  test "requires exactly one address" do
    assert_raise Mix.Error, ~r/usage/, fn -> MemberInvitationToken.run([]) end
  end
end
