defmodule SimpleFit.Observability.RedactionTest do
  @moduledoc """
  Free-text redaction (SF-29, ADR 0019): planted canaries in every
  credential and personal-data form, through unexpected failures that
  nobody sanitized on purpose. Canaries are long and unique, and assertions
  check that no part of them survives, never that short substrings are absent
  from random text.
  """

  # Not async: crashes processes, changes the log level and collects Sentry reports.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SimpleFit.Observability.Redaction

  @marker "CANARYsf29x7Q2v9Lk4Rz8Wm3Nt6Hy1Bp5Jd0"

  # Realistic shapes of each secret, each carrying the marker.
  defp canaries do
    %{
      access: "sfa_SFMyNTY.g2gDbQAAACQ#{@marker}.bWF4X2FnZQ",
      refresh: "sfr_#{@marker}abcdefghijklmn",
      link: "sfv_#{@marker}0123456789abcd",
      registration: "sfg_#{@marker}0123456789efgh",
      invitation: "sfi_#{@marker}0123456789ijkl",
      staff_invitation: "sfs_#{@marker}0123456789mnop",
      member_invitation: "sgm_#{@marker}0123456789qrst",
      jwt: "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ#{@marker}.c2lnbmF0dXJl#{@marker}",
      email: "#{String.downcase(@marker)}@example.com",
      full_name: "Full #{@marker} Name",
      date_of_birth: "1990-01-#{@marker}",
      code: "#{@marker}-otp",
      nonce: "nonce-#{@marker}"
    }
  end

  defp refute_canaries(text, label) do
    refute text =~ @marker, "#{label} leaks a canary:\n#{text}"
    refute text =~ String.downcase(@marker), "#{label} leaks a canary:\n#{text}"
  end

  describe "redact/1" do
    test "removes every credential and personal-data form, whole" do
      c = canaries()

      texts = [
        "Bearer #{c.access}",
        "authorization: Bearer #{c.access}",
        "refresh=#{c.refresh}&x=1",
        "token: #{c.link}",
        "the token #{c.registration} expired",
        "id_token=#{c.jwt}",
        "bare jwt #{c.jwt} here",
        inspect(%{"refresh_token" => c.refresh, "email" => c.email}),
        inspect(%{"full_name" => c.full_name, "date_of_birth" => c.date_of_birth}),
        inspect(%{"code" => c.code, "nonce" => c.nonce}),
        inspect(code: c.code, identity_token: c.jwt, email: c.email),
        "user #{c.email} failed",
        ~s({"email":"#{c.email}","code":"#{c.code}"})
      ]

      for text <- texts, do: refute_canaries(Redaction.redact(text), inspect(text))
    end

    test "keeps the operational meaning of the text" do
      assert Redaction.redact("refresh token reuse: session revoked") ==
               "refresh token reuse: session revoked"

      assert Redaction.redact("request completed route=/api/me status=401") ==
               "request completed route=/api/me status=401"

      assert Redaction.redact(%{not: "text"}) == %{not: "text"}
    end
  end

  describe "logs and Sentry, on failures nobody sanitized" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      Sentry.Test.start_collecting_sentry_reports()
      on_exit(fn -> Logger.configure(level: level) end)
      :ok
    end

    test "an error logged with inspect output of a request's params" do
      c = canaries()

      log =
        capture_log(fn ->
          require Logger

          Logger.error(
            "authentication failed unexpectedly: " <>
              inspect(%{
                "refresh_token" => c.refresh,
                "id_token" => c.jwt,
                "email" => c.email,
                "full_name" => c.full_name,
                "date_of_birth" => c.date_of_birth,
                "code" => c.code
              })
          )
        end)

      assert log =~ "authentication failed unexpectedly"
      refute_canaries(log, "log")
      events = Sentry.Test.pop_sentry_reports()
      assert events != [], "an error log stays actionable: it reaches Sentry"
      refute_canaries(inspect(events, limit: :infinity), "Sentry")
    end

    test "a process that crashes with a credential in its exception message" do
      c = canaries()

      log =
        capture_log(fn ->
          {:ok, pid} =
            Task.start(fn ->
              raise "provider rejected #{c.jwt} for #{c.email} with #{c.refresh}"
            end)

          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
          # Let the crash report reach the handlers.
          Process.sleep(100)
        end)

      assert log =~ "RuntimeError"
      refute_canaries(log, "crash log")
      events = Sentry.Test.pop_sentry_reports()
      assert events != [], "an unexpected crash stays actionable: it reaches Sentry"
      refute_canaries(inspect(events, limit: :infinity), "Sentry crash event")
    end

    test "a server that crashes holding credentials and personal data in its state" do
      c = canaries()

      log =
        capture_log(fn ->
          {:ok, pid} = GenServer.start(__MODULE__.Holder, c)
          ref = Process.monitor(pid)
          GenServer.cast(pid, :crash)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
          Process.sleep(100)
        end)

      assert log =~ "terminating"
      refute_canaries(log, "GenServer crash log")
      refute_canaries(inspect(Sentry.Test.pop_sentry_reports(), limit: :infinity), "Sentry")
    end
  end

  defmodule Holder do
    @moduledoc false
    use GenServer

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_cast(:crash, state), do: raise(ArgumentError, "bad state for #{state.email}")
  end
end
