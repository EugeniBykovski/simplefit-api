defmodule SimpleFitWeb.Schemas.FirstRunExperience do
  @moduledoc "OpenAPI schema: one first-run experience of the viewer (ADR 0018)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.FirstRun

  OpenApiSpex.schema(
    %{
      title: "FirstRunExperience",
      description:
        "A one-time first-run experience and whether the viewer should still be offered it.",
      type: :object,
      required: [:experience, :status, :recorded_at],
      additionalProperties: false,
      properties: %{
        experience: %Schema{
          type: :string,
          enum: Enum.map(FirstRun.experiences(), &Atom.to_string/1),
          description:
            "`fighter_web_tour`: the Fighter web Home tour, available once Fighter onboarding is complete."
        },
        status: %Schema{
          type: :string,
          enum: ["unavailable", "pending", "completed", "dismissed"],
          description: """
          `unavailable`: the viewer cannot have it yet. `pending`: offer it. `completed` / `dismissed`: the
          viewer finished or ended it; never offer it again.
          """
        },
        recorded_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the outcome was recorded; `null` until then."
        }
      },
      example: %{experience: "fighter_web_tour", status: "pending", recorded_at: nil}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.FirstRunResponse do
  @moduledoc "OpenAPI schema: every first-run experience of the viewer (ADR 0018)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.FirstRunExperience

  OpenApiSpex.schema(
    %{
      title: "FirstRunResponse",
      description: "The viewer's first-run experiences, one entry per known experience.",
      type: :object,
      required: [:experiences],
      additionalProperties: false,
      properties: %{experiences: %Schema{type: :array, items: FirstRunExperience}},
      example: %{
        experiences: [%{experience: "fighter_web_tour", status: "pending", recorded_at: nil}]
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.FirstRunExperienceResponse do
  @moduledoc "OpenAPI schema: one first-run experience after recording its outcome (ADR 0018)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.FirstRunExperience

  OpenApiSpex.schema(
    %{
      title: "FirstRunExperienceResponse",
      description: "The experience's state; `status` is the outcome that is kept.",
      type: :object,
      required: [:experience],
      additionalProperties: false,
      properties: %{experience: FirstRunExperience},
      example: %{
        experience: %{
          experience: "fighter_web_tour",
          status: "dismissed",
          recorded_at: "2026-10-10T09:00:00.000000Z"
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.FirstRunOutcomeRequest do
  @moduledoc "OpenAPI schema: how the viewer left a first-run experience (ADR 0018)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "FirstRunOutcomeRequest",
      description: "`completed`: the viewer finished it. `dismissed`: the viewer ended it early.",
      type: :object,
      required: [:outcome],
      additionalProperties: false,
      properties: %{outcome: %Schema{type: :string, enum: ["completed", "dismissed"]}},
      example: %{outcome: "completed"}
    },
    struct?: false
  )
end
