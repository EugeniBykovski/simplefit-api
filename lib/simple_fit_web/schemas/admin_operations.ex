defmodule SimpleFitWeb.Schemas.AdminOperationsCheck do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminOperationsCheck",
    description: """
    One measured check (SF-126). `status`: `healthy` (measured fine), `degraded` (measured, with failures in
    the window), `unavailable` (the measurement itself failed), `unknown` (measured, but the signal can't say),
    `no_telemetry` (nothing is measured; `observed_at` is null). Unknown is never healthy, and a failed
    measurement is never zero.
    """,
    type: :object,
    required: [:id, :status, :observed_at, :counts, :last_event_at],
    properties: %{
      id: %Schema{
        type: :string,
        enum: ~w(api database background_jobs email payments_webhooks storage error_monitoring)
      },
      status: %Schema{type: :string, enum: ~w(healthy degraded unavailable unknown no_telemetry)},
      observed_at: %Schema{type: :string, format: :"date-time", nullable: true},
      counts: %Schema{
        type: :array,
        description:
          "Measured numbers behind the status: database `query_ms`; jobs `waiting`, `executing`, `failed_24h`; " <>
            "email `accepted_24h` (accepted by the provider, not delivered), `failed_24h`, `pending`; webhooks " <>
            "`received_24h`, `processed_24h`, `ignored_24h`, `failed_24h`.",
        items: %Schema{
          type: :object,
          required: [:key, :value],
          properties: %{key: %Schema{type: :string}, value: %Schema{type: :integer, minimum: 0}}
        }
      },
      last_event_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminOperationsHealthResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminOperationsCheck

  @states ~w(available scheduled executing retryable completed discarded cancelled)

  OpenApiSpex.schema(%{
    title: "AdminOperationsHealthResponse",
    description: """
    The system health page (AD17). Each check is its own observation, not one atomic snapshot. No uptime or
    SLA: no history is kept. Queue counts: unfinished jobs, plus finished ones from the last 24 hours (Oban
    prunes them after a day). `queues`, `migrations` are null when they couldn't be measured.
    """,
    type: :object,
    required: [:health],
    properties: %{
      health: %Schema{
        type: :object,
        required: [:observed_at, :checks, :queues, :migrations, :release],
        properties: %{
          observed_at: %Schema{type: :string, format: :"date-time"},
          checks: %Schema{type: :array, items: AdminOperationsCheck},
          queues: %Schema{
            type: :array,
            nullable: true,
            items: %Schema{
              type: :object,
              required: [:name, :limit, :counts],
              properties: %{
                name: %Schema{type: :string},
                limit: %Schema{type: :integer, minimum: 0, description: "Configured concurrency."},
                counts: %Schema{
                  type: :object,
                  required: @states,
                  properties: Map.new(@states, &{&1, %Schema{type: :integer, minimum: 0}})
                }
              }
            }
          },
          migrations: %Schema{
            type: :object,
            nullable: true,
            required: [:applied, :latest_version],
            properties: %{
              applied: %Schema{type: :integer, minimum: 0},
              latest_version: %Schema{type: :string, nullable: true}
            }
          },
          release: %Schema{
            type: :object,
            required: [:release, :environment, :source],
            properties: %{
              release: %Schema{type: :string},
              environment: %Schema{type: :string},
              source: %Schema{
                type: :string,
                enum: ~w(configured default),
                description:
                  "`configured`: supplied by the deployment; `default`: none was, the app version stands in."
              }
            }
          }
        }
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminJob do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @time %Schema{type: :string, format: :"date-time", nullable: true}

  OpenApiSpex.schema(%{
    title: "AdminJob",
    description: """
    One background job's metadata (SF-126): never its arguments, `meta`, error messages or stack traces.
    `failure` is only the exception module of the last error. `retry` is always `not_supported`: no worker
    has an approved retry policy.
    """,
    type: :object,
    required: [
      :id,
      :queue,
      :worker,
      :state,
      :attempt,
      :max_attempts,
      :inserted_at,
      :scheduled_at,
      :attempted_at,
      :completed_at,
      :discarded_at,
      :cancelled_at,
      :failure,
      :errors,
      :retry
    ],
    properties: %{
      id: %Schema{type: :integer, minimum: 1},
      queue: %Schema{type: :string},
      worker: %Schema{type: :string},
      state: %Schema{
        type: :string,
        enum: ~w(available scheduled executing retryable completed discarded cancelled)
      },
      attempt: %Schema{type: :integer, minimum: 0},
      max_attempts: %Schema{type: :integer, minimum: 1},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      scheduled_at: @time,
      attempted_at: @time,
      completed_at: @time,
      discarded_at: @time,
      cancelled_at: @time,
      failure: %Schema{type: :string, nullable: true},
      errors: %Schema{
        type: :integer,
        minimum: 0,
        description: "How many attempts recorded an error."
      },
      retry: %Schema{type: :string, enum: ["not_supported"]}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminJobListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminJob

  OpenApiSpex.schema(%{
    title: "AdminJobListResponse",
    type: :object,
    required: [:jobs, :next_cursor],
    properties: %{
      jobs: %Schema{type: :array, items: AdminJob, maxItems: 50},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminJobResponse do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.AdminJob

  OpenApiSpex.schema(%{
    title: "AdminJobResponse",
    type: :object,
    required: [:job],
    properties: %{job: AdminJob}
  })
end
