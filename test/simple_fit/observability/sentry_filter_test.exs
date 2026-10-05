defmodule SimpleFit.Observability.SentryFilterTest do
  # Uses the global Sentry logger handler.
  use SimpleFitWeb.ConnCase, async: false

  require Logger

  alias Sentry.Interfaces
  alias SimpleFit.Observability.SentryFilter
  alias SimpleFitWeb.FallbackController

  @secrets [
    "Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature",
    "AKIAABCDEFGHIJKLMNOP",
    "re_live_1234567890abcdefXYZ",
    "X-Amz-Signature=deadbeefcafebabe",
    "password=hunter2"
  ]

  # The keys Sentry sends (mirrors Sentry.Event.remove_non_payload_keys/1):
  # `original_exception` is kept in memory for callbacks, never sent.
  defp payload(event) do
    event
    |> Map.from_struct()
    |> Map.drop([:original_exception, :source, :attachments, :integration_meta])
  end

  describe "before_send/1" do
    test "keeps operational data and strips request, user, payload and secrets" do
      event = %Sentry.Event{
        event_id: "0",
        timestamp: "2026-10-05T00:00:00Z",
        message: %Interfaces.Message{formatted: "failed: #{Enum.join(@secrets, " ")}"},
        exception: [
          %Interfaces.Exception{
            type: "RuntimeError",
            value: "upstream said #{Enum.join(@secrets, ", ")}",
            stacktrace: %Interfaces.Stacktrace{
              frames: [
                %Interfaces.Stacktrace.Frame{
                  module: SimpleFit.Email,
                  function: "deliver/2",
                  vars: %{"arg0" => "athlete@example.com"}
                }
              ]
            }
          }
        ],
        request: %Interfaces.Request{
          headers: %{"authorization" => "Bearer abc"},
          cookies: %{"session" => "s"},
          data: %{"note" => "coach note"}
        },
        user: %{email: "athlete@example.com"},
        extra: %{
          args: %{"message" => %{"to" => ["athlete@example.com"]}},
          meta: %{"x" => 1},
          worker: "SimpleFit.Email.DeliveryWorker",
          attempt: 5,
          logger_metadata: %{request_id: "req-1", email: "athlete@example.com"}
        }
      }

      sanitized = SentryFilter.before_send(event)
      encoded = inspect(sanitized, limit: :infinity, printable_limit: :infinity)

      for secret <- @secrets ++ ["hunter2", "athlete@example.com", "coach note", "eyJhbGci"] do
        refute encoded =~ secret, "leaked #{secret}"
      end

      assert sanitized.request == %Interfaces.Request{}
      assert sanitized.user == %{}

      assert sanitized.extra == %{
               worker: "SimpleFit.Email.DeliveryWorker",
               attempt: 5,
               logger_metadata: %{request_id: "req-1"}
             }

      [%{stacktrace: %{frames: [frame]}}] = sanitized.exception
      assert frame.vars == nil
      assert frame.function == "deliver/2"
    end
  end

  test "Oban errors are reported only when the job exhausts its attempts" do
    refute SentryFilter.report_job_error?(nil, %Oban.Job{attempt: 1, max_attempts: 5})
    assert SentryFilter.report_job_error?(nil, %Oban.Job{attempt: 5, max_attempts: 5})
  end

  describe "event policy (through Sentry.LoggerHandler)" do
    setup do
      Sentry.Test.start_collecting_sentry_reports()
    end

    test "a crash is captured once, sanitized, with the request id tag" do
      exception = %RuntimeError{message: "db failed with password=hunter2"}

      Logger.metadata(request_id: "req-crash")
      # How crash reports arrive (Bandit, process crashes): :logger with crash_reason.
      :logger.error("crash", %{crash_reason: {exception, []}})

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.tags[:request_id] == "req-crash" or event.tags["request_id"] == "req-crash"
      # What Sentry would receive (original_exception stays local).
      refute event |> payload() |> inspect(limit: :infinity) =~ "hunter2"
    after
      Logger.metadata(request_id: nil)
    end

    test "an unhandled context error is captured; expected API errors are not", %{conn: conn} do
      conn = Plug.RequestId.call(conn, Plug.RequestId.init([]))

      for reason <- [:not_found, :forbidden, :conflict, :timeout, :rate_limited] do
        FallbackController.call(conn, {:error, reason})
      end

      get(build_conn(), "/api/does-not-exist")
      assert Sentry.Test.pop_sentry_reports() == []

      FallbackController.call(conn, {:error, {:unexpected, "token=abc123"}})
      assert [event] = Sentry.Test.pop_sentry_reports()
      refute event |> payload() |> inspect(limit: :infinity) =~ "abc123"
    end

    test "warnings are never sent" do
      Logger.warning("provider request failed", provider: "resend", reason: :timeout)
      assert Sentry.Test.pop_sentry_reports() == []
    end
  end
end
