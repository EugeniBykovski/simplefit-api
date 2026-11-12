defmodule SimpleFitWeb.Schemas.AdminConfigurationFlag do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminConfigurationFlag",
    description: """
    One registered feature switch (SF-128). `deployment_value` is what the deployment's environment variable
    set (a boolean, or `test`/`live` for the Stripe mode); `suspended` is an operator's runtime suspension;
    `effective` is what the consumer sees now. `control`: `suspendable` (an operator may suspend and restore
    it; it can never be enabled beyond the deployment), `read_only` (deployment only), `build` (read when the
    API is built: changes need a new build). `flag_id` and `revision` exist only for suspendable switches.
    """,
    type: :object,
    required: [
      :key,
      :group,
      :variable,
      :consumer,
      :control,
      :risk,
      :decision,
      :impact,
      :deployment_value,
      :suspended,
      :effective,
      :flag_id,
      :revision,
      :updated_at
    ],
    properties: %{
      key: %Schema{type: :string},
      group: %Schema{type: :string, enum: ~w(gyms sponsors coaching payments platform)},
      variable: %Schema{type: :string, description: "The environment variable that sets it."},
      consumer: %Schema{type: :string, description: "The code that reads it."},
      control: %Schema{type: :string, enum: ~w(suspendable read_only build)},
      risk: %Schema{type: :string, enum: ~w(low medium high), description: "Backend-registered."},
      decision: %Schema{type: :string, description: "The decision or ticket that governs it."},
      impact: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "What a suspension does."
      },
      deployment_value: %Schema{
        oneOf: [%Schema{type: :boolean}, %Schema{type: :string, enum: ["test", "live"]}]
      },
      suspended: %Schema{type: :boolean},
      effective: %Schema{
        oneOf: [%Schema{type: :boolean}, %Schema{type: :string, enum: ["test", "live"]}]
      },
      flag_id: %Schema{type: :string, format: :uuid, nullable: true},
      revision: %Schema{type: :integer, minimum: 1, nullable: true},
      updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminConfigurationChange do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AdminConfigurationChange",
    description: "One change of a runtime flag: append-only history.",
    type: :object,
    required: [
      :revision,
      :change,
      :suspended,
      :previous_suspended,
      :operator_id,
      :reason_code,
      :changed_at
    ],
    properties: %{
      key: %Schema{type: :string},
      revision: %Schema{type: :integer, minimum: 2},
      change: %Schema{type: :string, enum: ["suspend", "restore"]},
      suspended: %Schema{type: :boolean},
      previous_suspended: %Schema{type: :boolean},
      operator_id: %Schema{type: :string, format: :uuid},
      reason_code: %Schema{type: :string},
      changed_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminConfigurationResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{AdminConfigurationChange, AdminConfigurationFlag}

  OpenApiSpex.schema(%{
    title: "AdminConfigurationResponse",
    description: """
    The configuration inventory (SF-128): every registered switch of this deployment, and the newest changes.
    Secrets, credentials, URLs, provider and operator settings are never registered or shown.
    """,
    type: :object,
    required: [:configuration],
    properties: %{
      configuration: %Schema{
        type: :object,
        required: [:environment, :observed_at, :flags, :changes],
        properties: %{
          environment: %Schema{
            type: :string,
            description: "This deployment's environment; changes only ever apply here."
          },
          observed_at: %Schema{type: :string, format: :"date-time"},
          flags: %Schema{type: :array, items: AdminConfigurationFlag},
          changes: %Schema{type: :array, items: AdminConfigurationChange}
        }
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.AdminConfigurationFlagResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{AdminConfigurationChange, AdminConfigurationFlag}

  OpenApiSpex.schema(%{
    title: "AdminConfigurationFlagResponse",
    type: :object,
    required: [:flag],
    properties: %{
      flag: %Schema{
        allOf: [
          AdminConfigurationFlag,
          %Schema{
            type: :object,
            properties: %{history: %Schema{type: :array, items: AdminConfigurationChange}}
          }
        ]
      }
    }
  })
end

for {module, action, description} <- [
      {SimpleFitWeb.Schemas.SuspendRuntimeFlagRequest, "config.flag.suspend",
       "Suspend an allowlisted feature (SF-128): off whatever the deployment says, until restored."},
      {SimpleFitWeb.Schemas.RestoreRuntimeFlagRequest, "config.flag.restore",
       "Restore a suspended feature (SF-128): the deployment decides again."}
    ] do
  defmodule module do
    @moduledoc false
    require OpenApiSpex
    alias SimpleFit.Operators.ConfigurationActions
    alias SimpleFitWeb.Schemas.SponsorDecisionRequests

    OpenApiSpex.schema(
      SponsorDecisionRequests.schema(
        module |> Module.split() |> List.last(),
        Map.fetch!(ConfigurationActions.reasons(), action),
        description
      ),
      struct?: false
    )
  end
end
