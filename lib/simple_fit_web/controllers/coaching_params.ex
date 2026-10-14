defmodule SimpleFitWeb.CoachingParams do
  @moduledoc """
  OpenAPI parameters shared by the Coach–Fighter relationship operations
  (ADR 0021).
  """

  alias OpenApiSpex.{Parameter, Schema}

  @doc "`status`, `limit` and `cursor` of a relationship list."
  @spec list() :: [Parameter.t()]
  def list do
    [
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "`active` (default) or `ended`.",
        schema: %Schema{type: :string, enum: ["active", "ended"], default: "active"}
      },
      %Parameter{
        name: :limit,
        in: :query,
        required: false,
        description: "Page size, 1-100 (default 50).",
        schema: %Schema{type: :integer, minimum: 1, maximum: 100, default: 50}
      },
      %Parameter{
        name: :cursor,
        in: :query,
        required: false,
        description: "`next_cursor` of the previous page, for the same `status`.",
        schema: %Schema{type: :string}
      }
    ]
  end

  @doc "The `relationship_id` path parameter."
  @spec relationship_id() :: Parameter.t()
  def relationship_id do
    %Parameter{
      name: :relationship_id,
      in: :path,
      required: true,
      description: "The relationship.",
      schema: %Schema{type: :string, format: :uuid}
    }
  end
end
