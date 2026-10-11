defmodule Mix.Tasks.E2e.EmailCodeTest do
  # Not async: switches the Mix shell.
  use SimpleFit.DataCase, async: false

  import SimpleFit.EmailAuthHelpers

  alias Mix.Tasks.E2e.EmailCode
  alias SimpleFit.Accounts

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "prints only the latest code queued to the address" do
    {:ok, _} = Accounts.request_email_registration("e2e-code@example.com", "127.0.0.1")
    {:ok, _} = Accounts.request_email_registration("other@example.com", "127.0.0.1")
    expected = code_from(last_email_to("e2e-code@example.com"))

    EmailCode.run(["E2E-Code@example.com"])

    assert_received {:mix_shell, :info, [^expected]}
    refute_received {:mix_shell, :info, _}
  end

  test "fails when nothing was sent to the address" do
    assert_raise Mix.Error, ~r/no code queued/, fn -> EmailCode.run(["nobody@example.com"]) end
  end

  test "refuses to run where the end-to-end tools are not enabled (prod)" do
    {:ok, _} = Accounts.request_email_registration("e2e-code@example.com", "127.0.0.1")
    Application.put_env(:simple_fit, :e2e_tools, enabled: false)
    on_exit(fn -> Application.put_env(:simple_fit, :e2e_tools, enabled: true) end)

    assert_raise Mix.Error, ~r/only where :e2e_tools is enabled/, fn ->
      EmailCode.run(["e2e-code@example.com"])
    end

    refute_received {:mix_shell, :info, _}
  end

  test "requires exactly one address" do
    assert_raise Mix.Error, ~r/usage/, fn -> EmailCode.run([]) end
  end
end
