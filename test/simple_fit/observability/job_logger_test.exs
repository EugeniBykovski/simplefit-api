defmodule SimpleFit.Observability.JobLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SimpleFit.Observability.JobLogger

  @metadata [:worker, :queue, :job_id, :attempt, :max_attempts, :state, :error_kind, :error_type]

  # Calls the handler directly with Oban's event shape: our policy, not
  # Oban's or other handlers' behaviour, is under test.
  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  defp job do
    %Oban.Job{
      id: 42,
      worker: "SimpleFit.Email.DeliveryWorker",
      queue: "mailers",
      attempt: 2,
      max_attempts: 5,
      args: %{
        "message" => %{"to" => ["athlete@example.com"], "subject" => "Your injury report"}
      },
      meta: %{"note" => "private"}
    }
  end

  test "logs job identity and outcome, never args or meta" do
    log =
      capture_log([level: :info, metadata: @metadata], fn ->
        JobLogger.handle_event(
          [:oban, :job, :stop],
          %{duration: 1_000_000},
          %{
            job: job(),
            state: :success
          },
          nil
        )
      end)

    assert log =~ "job completed"
    assert log =~ "worker=SimpleFit.Email.DeliveryWorker"
    assert log =~ "queue=mailers"
    assert log =~ "job_id=42"
    assert log =~ "attempt=2"
    assert log =~ "state=success"
    refute log =~ "athlete@example.com"
    refute log =~ "injury"
    refute log =~ "private"
  end

  test "logs failures at warning with the error type only" do
    error = %Oban.PerformError{reason: {:error, :timeout}}

    log =
      capture_log([level: :info, metadata: @metadata], fn ->
        JobLogger.handle_event(
          [:oban, :job, :exception],
          %{duration: 1_000},
          %{
            job: job(),
            state: :failure,
            kind: :error,
            reason: error,
            stacktrace: []
          },
          nil
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "job failed"
    assert log =~ "error_type=timeout"
    refute log =~ "athlete@example.com"
  end
end
