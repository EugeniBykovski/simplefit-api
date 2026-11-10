defmodule SimpleFitWeb.Schemas.SponsorFirstRun do
  @moduledoc "OpenAPI schema: the viewer's partner portal first run (SF-119)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @timestamp %Schema{type: :string, format: :"date-time", nullable: true}

  OpenApiSpex.schema(
    %{
      title: "SponsorFirstRun",
      description: """
      The viewer's introduction to one sponsor organization's portal (SRW1 welcome, SRW2 tour), per organization and
      member, the same on every client. Presentation only: it grants, restores or changes no access.
      """,
      type: :object,
      additionalProperties: false,
      required: [:sponsor_id, :status, :started_at, :completed_at, :dismissed_at],
      properties: %{
        sponsor_id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ["unavailable", "not_started", "in_progress", "completed", "dismissed"],
          description: """
          `unavailable`: the organization is suspended (no introduction while it is). `not_started`: offer it.
          `in_progress`: started on some client and not ended; offer to resume. `completed` / `dismissed`: final;
          never offer it again (replaying the tour is client-only and records nothing).
          """
        },
        started_at: %{
          @timestamp
          | description: "When the tour was started; `null` if never (or dismissed unstarted)."
        },
        completed_at: %{@timestamp | description: "When it was finished; `null` otherwise."},
        dismissed_at: %{
          @timestamp
          | description: "When it was dismissed or ended; `null` otherwise."
        }
      },
      example: %{
        sponsor_id: "4c2e8a1d-6b3f-4e7a-9c5d-2f1b8e3a7d60",
        status: "not_started",
        started_at: nil,
        completed_at: nil,
        dismissed_at: nil
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorFirstRunResponse do
  @moduledoc "OpenAPI schema: one partner portal first run."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.SponsorFirstRun

  OpenApiSpex.schema(
    %{
      title: "SponsorFirstRunResponse",
      type: :object,
      additionalProperties: false,
      required: [:first_run],
      properties: %{first_run: SponsorFirstRun}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorFirstRunTransitionRequest do
  @moduledoc "OpenAPI schema: the (empty) body of a partner portal first-run transition (SF-119)."

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "SponsorFirstRunTransitionRequest",
      description: """
      No fields: the organization comes from the path and the user from the session. Any field (a `user_id`, a
      step) answers `422 validation_error`.
      """,
      type: :object,
      additionalProperties: false,
      properties: %{}
    },
    struct?: false
  )
end
