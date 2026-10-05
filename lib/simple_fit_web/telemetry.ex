defmodule SimpleFitWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor and metric definitions.

  `metrics/0` is the list a reporter (Prometheus, StatsD, OpenTelemetry) will
  consume once one is added; none is attached yet. See
  docs/architecture/README.md, "Observability".
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("simple_fit.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("simple_fit.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("simple_fit.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("simple_fit.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("simple_fit.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Provider boundaries (SimpleFit.Email, SimpleFit.Storage). `result` is
      # :ok or a SimpleFit.Provider error reason.
      summary("simple_fit.email.deliver.stop.duration",
        tags: [:adapter, :result],
        unit: {:native, :millisecond}
      ),
      counter("simple_fit.storage.presign.stop.duration", tags: [:adapter, :method, :result]),

      # Background jobs (Oban)
      summary("oban.job.stop.duration",
        tags: [:queue, :worker, :state],
        tag_values: &oban_job_tags/1,
        unit: {:native, :millisecond}
      ),
      counter("oban.job.exception.duration",
        tags: [:queue, :worker],
        tag_values: &oban_job_tags/1
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp oban_job_tags(%{job: job} = metadata) do
    %{queue: job.queue, worker: job.worker, state: Map.get(metadata, :state)}
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {SimpleFitWeb, :count_users, []}
    ]
  end
end
