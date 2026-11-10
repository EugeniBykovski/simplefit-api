defmodule SimpleFitWeb.Schemas.AdminOverviewCount do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminOverviewCount",
    description: "One named count.",
    type: :object,
    required: [:key, :value],
    properties: %{
      key: %Schema{type: :string},
      value: %Schema{type: :integer, minimum: 0}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminOverviewMetric do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminOverviewCount

  OpenApiSpex.schema(%{
    title: "AdminOverviewMetric",
    description: """
    One overview metric (definitions: simplefit-api docs/architecture/admin-overview-metrics.md).

    * `state: available` - `value` is the count as of `as_of` (0 is a real zero); `breakdown` splits it
      by status, `period_counts` are the explicit "in period" counts.
    * `state: restricted` - the operator lacks this metric's permission: no value, never 0.
    * `state: unavailable` - SimpleFit can't produce this metric yet: no value, never 0.

    `id`: `accounts` (account registration complete; breakdown `in_progress`, `not_started`; period
    `registration_completed`), `fighter_profiles` and `coach_profiles` (onboarding completed; breakdown
    `in_progress`; period `onboarding_completed`), `gyms` (setup completed; breakdown `draft`; period
    `setup_completed`), `sponsor_organizations` (active, provisioned from an approved application;
    breakdown `suspended`, `closed`; period `approved`), `operators` (active), `sponsor_applications_waiting`
    (submitted or under review; breakdown by every non-draft status; period `first_submitted`, `approved`,
    `rejected`), `gym_verifications_waiting` (always unavailable today).
    """,
    type: :object,
    required: [:id, :group, :state, :value, :breakdown, :period_counts],
    properties: %{
      id: %Schema{
        type: :string,
        enum: ~w(accounts fighter_profiles coach_profiles gyms sponsor_organizations operators
                 sponsor_applications_waiting gym_verifications_waiting)
      },
      group: %Schema{type: :string, enum: ~w(population reviews)},
      state: %Schema{type: :string, enum: ~w(available restricted unavailable)},
      value: %Schema{type: :integer, minimum: 0, nullable: true},
      breakdown: %Schema{type: :array, items: AdminOverviewCount},
      period_counts: %Schema{type: :array, items: AdminOverviewCount}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminOverviewCheck do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.AdminOverviewCount

  OpenApiSpex.schema(%{
    title: "AdminOverviewCheck",
    description: """
    One health check, from a real signal only; nothing is called healthy without a check.

    * `database` - `healthy` when the overview's own queries answered.
    * `background_jobs` - Oban's table: `counts` `waiting` and `discarded_24h`; `degraded` when any job
      was discarded (retries exhausted) in the last 24 hours, else `healthy`.
    * `payments_webhooks` - always `unknown`; `last_event_at` is when the last Stripe webhook arrived.
    * `email_provider` - `no_telemetry`: the provider reports nothing to SimpleFit.
    """,
    type: :object,
    required: [:id, :status, :counts, :last_event_at],
    properties: %{
      id: %Schema{
        type: :string,
        enum: ~w(database background_jobs payments_webhooks email_provider)
      },
      status: %Schema{
        type: :string,
        enum: ~w(healthy degraded unknown no_telemetry unavailable)
      },
      counts: %Schema{type: :array, items: AdminOverviewCount},
      last_event_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminOverview do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{AdminOverviewCheck, AdminOverviewMetric}

  OpenApiSpex.schema(%{
    title: "AdminOverview",
    description:
      "Platform counts, review queues and health as one snapshot at `as_of`. `period` is `[from, to)` " <>
        "in UTC and drives only `period_counts`. `health.state: restricted` means no `system.health.read`.",
    type: :object,
    required: [:as_of, :period, :metrics, :health],
    properties: %{
      as_of: %Schema{type: :string, format: :"date-time"},
      period: %Schema{
        type: :object,
        required: [:key, :from, :to],
        properties: %{
          key: %Schema{type: :string, enum: ~w(24h 7d 30d)},
          from: %Schema{type: :string, format: :"date-time"},
          to: %Schema{type: :string, format: :"date-time"}
        }
      },
      metrics: %Schema{type: :array, items: AdminOverviewMetric},
      health: %Schema{
        type: :object,
        required: [:state, :checks],
        properties: %{
          state: %Schema{type: :string, enum: ~w(available restricted)},
          checks: %Schema{type: :array, items: AdminOverviewCheck}
        }
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminOverviewResponse do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.AdminOverview

  OpenApiSpex.schema(%{
    title: "AdminOverviewResponse",
    type: :object,
    required: [:overview],
    properties: %{overview: AdminOverview}
  })
end
