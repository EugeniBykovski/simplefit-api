defmodule SimpleFitWeb.TrainingParams do
  @moduledoc "OpenAPI parameters shared by the training session operations (ADR 0023)."

  alias OpenApiSpex.{Parameter, Schema}

  @doc "The list filters and paging of either side (`:coach` adds `relationship_id`)."
  @spec list(:coach | :fighter) :: [Parameter.t()]
  def list(side) do
    [
      %Parameter{
        name: :view,
        in: :query,
        required: false,
        description: """
        A projection computed with the server's clock: `upcoming` - planned sessions not yet over
        (`starts_at` + `duration_minutes` after now), earliest first; `history` - completed, cancelled and past-due
        planned sessions, newest first. Without it: every session, earliest first.
        """,
        schema: %Schema{type: :string, enum: ["upcoming", "history"]}
      },
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "Only sessions in this status.",
        schema: %Schema{type: :string, enum: ["planned", "completed", "cancelled"]}
      },
      %Parameter{
        name: :from,
        in: :query,
        required: false,
        description: "Only sessions starting at or after this instant (RFC 3339 with offset).",
        schema: %Schema{type: :string, format: :"date-time"}
      },
      %Parameter{
        name: :to,
        in: :query,
        required: false,
        description:
          "Only sessions starting before this instant (RFC 3339 with offset; not before `from`).",
        schema: %Schema{type: :string, format: :"date-time"}
      }
    ] ++
      if(side == :coach,
        do: [
          %Parameter{
            name: :relationship_id,
            in: :query,
            required: false,
            description: "Only sessions of this relationship (one of the coach's active ones).",
            schema: %Schema{type: :string, format: :uuid}
          }
        ],
        else: []
      ) ++
      [
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
          description: "`next_cursor` of the previous page, with the same `view` and filters.",
          schema: %Schema{type: :string}
        }
      ]
  end

  @doc "The `session_id` path parameter."
  @spec session_id() :: Parameter.t()
  def session_id do
    %Parameter{
      name: :session_id,
      in: :path,
      required: true,
      description: "The training session.",
      schema: %Schema{type: :string, format: :uuid}
    }
  end
end
