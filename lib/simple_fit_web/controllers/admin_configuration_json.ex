defmodule SimpleFitWeb.AdminConfigurationJSON do
  @moduledoc "Renders the operator configuration views (SF-128): allowlisted fields only."

  @fields [
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
  ]

  def index(%{configuration: c}) do
    %{
      configuration: %{
        environment: c.environment,
        observed_at: c.observed_at,
        flags: Enum.map(c.flags, &Map.take(&1, @fields)),
        changes: c.changes
      }
    }
  end

  def show(%{flag: flag}),
    do: %{flag: flag |> Map.take(@fields) |> Map.put(:history, Map.get(flag, :history, []))}
end
