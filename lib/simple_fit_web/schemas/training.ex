defmodule SimpleFitWeb.Schemas.TrainingFields do
  @moduledoc """
  Shared OpenAPI definitions of training sessions (ADR 0023). Vocabularies
  come from `SimpleFit.Training.TrainingSession`, so the contract cannot drift
  from what the backend accepts.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Training.TrainingSession

  @doc "The training type vocabulary (SF-49 §8.2.1)."
  def training_type do
    %Schema{
      type: :string,
      enum: Enum.map(TrainingSession.training_types(), &Atom.to_string/1),
      description: "What kind of training: one of five types (not a coaching format or level)."
    }
  end

  @doc "The writable plan properties, for requests and responses."
  def plan do
    %{
      title: %Schema{type: :string, minLength: 1, maxLength: 80, example: "Technical boxing"},
      training_type: training_type(),
      starts_at: %Schema{
        type: :string,
        format: :"date-time",
        description: """
        When the session starts: an RFC 3339 instant with an explicit offset (stored and returned in UTC).
        Clients resolve the coach's wall time in `time_zone` to the instant; an ambiguous (repeated) wall time
        needs an explicit choice of offset, and a wall time that does not exist cannot be sent. A non-UTC
        offset must be `time_zone`'s offset at that instant. When set, it lies between one day before and one
        year after now.
        """,
        example: "2026-10-24T08:00:00Z"
      },
      time_zone: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 64,
        description: """
        The IANA time zone the coach planned in (e.g. `Europe/Warsaw`; legacy aliases accepted), validated
        against the server's zone data. Clients show the start in this zone and in the viewer's own.
        """,
        example: "Europe/Warsaw"
      },
      duration_minutes: %Schema{type: :integer, minimum: 5, maximum: 600, example: 60},
      notes: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 2000,
        nullable: true,
        description: "The coach's plain-text notes for the fighter.",
        example: "Jab work and footwork."
      }
    }
  end

  @doc "The properties every session has, for either side."
  def session do
    plan()
    |> Map.merge(%{
      id: %Schema{type: :string, format: :uuid},
      relationship_id: %Schema{
        type: :string,
        format: :uuid,
        description: "The coaching relationship the session was assigned under."
      },
      status: %Schema{
        type: :string,
        enum: ["planned", "completed", "cancelled"],
        description: """
        `planned` until it ends: `cancelled` (by the coach, or by the system when the relationship ends) or
        `completed` (confirmed by the fighter, `completeMyTrainingSession`). Both are final.
        """
      },
      completed_at: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description:
          "When the fighter confirmed the session (set by the server, UTC, never changes); `null` unless completed."
      },
      cancelled_at: %Schema{type: :string, format: :"date-time", nullable: true},
      cancelled_by: %Schema{
        type: :string,
        # `null` is listed so strict validators accept a nullable enum.
        enum: ["coach", "system", nil],
        nullable: true,
        description: "`coach`, or `system` when the relationship ended; `null` unless cancelled."
      },
      cancel_reason: %Schema{
        type: :string,
        enum: ["relationship_ended", nil],
        nullable: true,
        description: "`relationship_ended` for a system cancellation; `null` otherwise."
      },
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    })
    |> Map.update!(:notes, &Map.put(&1, :description, "The coach's notes; `null` when none."))
  end

  @doc "The `next_cursor` of a page."
  def next_cursor do
    %Schema{
      type: :string,
      nullable: true,
      description: "Pass as `cursor` to read the next page; `null` on the last page. Opaque."
    }
  end
end

defmodule SimpleFitWeb.Schemas.CoachTrainingSession do
  @moduledoc "OpenAPI schema: one training session as its coach sees it."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.TrainingFields

  @properties TrainingFields.session()
              |> Map.put(:fighter, %Schema{
                type: :object,
                nullable: true,
                additionalProperties: false,
                required: [:display_name, :username],
                description: """
                The fighter, as the relationship discloses them: `display_name` and `username` when the accepted
                disclosure includes them, otherwise `null`. Nothing else of the fighter. `null` only if the
                relationship ended while the session was read.
                """,
                properties: %{
                  display_name: %Schema{type: :string, nullable: true},
                  username: %Schema{type: :string, nullable: true}
                }
              })

  OpenApiSpex.schema(
    %{
      title: "CoachTrainingSession",
      description:
        "A training session the coach assigned, under one of their active relationships.",
      type: :object,
      additionalProperties: false,
      required: @properties |> Map.keys() |> Enum.sort(),
      properties: @properties
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachTrainingSessionResponse do
  @moduledoc "OpenAPI schema: one session of the coach."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.CoachTrainingSession

  OpenApiSpex.schema(
    %{
      title: "CoachTrainingSessionResponse",
      type: :object,
      additionalProperties: false,
      required: [:training_session],
      properties: %{training_session: CoachTrainingSession}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachTrainingSessionList do
  @moduledoc "OpenAPI schema: one page of the coach's sessions."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{CoachTrainingSession, TrainingFields}

  OpenApiSpex.schema(
    %{
      title: "CoachTrainingSessionList",
      type: :object,
      additionalProperties: false,
      required: [:next_cursor, :training_sessions],
      properties: %{
        training_sessions: %Schema{
          type: :array,
          items: CoachTrainingSession,
          description: "By start, earliest first (then by id). Empty when there are none."
        },
        next_cursor: TrainingFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyTrainingSession do
  @moduledoc "OpenAPI schema: one training session as its fighter sees it."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.TrainingFields

  @properties TrainingFields.session()
              |> Map.merge(%{
                coach: %Schema{
                  type: :object,
                  nullable: true,
                  additionalProperties: false,
                  required: [:brand_name, :display_name],
                  description:
                    "The coach's public identity while the relationship is active; `null` once it has ended.",
                  properties: %{
                    display_name: %Schema{type: :string, nullable: true},
                    brand_name: %Schema{type: :string, nullable: true}
                  }
                },
                coach_display_name_at_end: %Schema{
                  type: :string,
                  nullable: true,
                  description:
                    "The coach's display name as it was when the relationship ended; `null` while active."
                }
              })

  OpenApiSpex.schema(
    %{
      title: "MyTrainingSession",
      description: "A training session assigned to the viewer (their own training history).",
      type: :object,
      additionalProperties: false,
      required: @properties |> Map.keys() |> Enum.sort(),
      properties: @properties
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyTrainingSessionResponse do
  @moduledoc "OpenAPI schema: one session of the fighter."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.MyTrainingSession

  OpenApiSpex.schema(
    %{
      title: "MyTrainingSessionResponse",
      type: :object,
      additionalProperties: false,
      required: [:training_session],
      properties: %{training_session: MyTrainingSession}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyTrainingSessionList do
  @moduledoc "OpenAPI schema: one page of the fighter's sessions."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{MyTrainingSession, TrainingFields}

  OpenApiSpex.schema(
    %{
      title: "MyTrainingSessionList",
      type: :object,
      additionalProperties: false,
      required: [:next_cursor, :training_sessions],
      properties: %{
        training_sessions: %Schema{
          type: :array,
          items: MyTrainingSession,
          description: "By start, earliest first (then by id). Empty when there are none."
        },
        next_cursor: TrainingFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.TrainingSessionCreateRequest do
  @moduledoc "OpenAPI schema: assigning a training session."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.TrainingFields

  @properties TrainingFields.plan()
              |> Map.merge(%{
                relationship_id: %Schema{
                  type: :string,
                  format: :uuid,
                  description:
                    "One of the coach's active relationships; the fighter is that relationship's."
                },
                client_request_id: %Schema{
                  type: :string,
                  format: :uuid,
                  description: """
                  A new UUID the client picks for this create and repeats on a retry. Another create with the same
                  key returns that session (`200`) and creates nothing.
                  """
                }
              })

  OpenApiSpex.schema(
    %{
      title: "TrainingSessionCreateRequest",
      type: :object,
      additionalProperties: false,
      required: [
        :client_request_id,
        :duration_minutes,
        :relationship_id,
        :starts_at,
        :time_zone,
        :title,
        :training_type
      ],
      properties: @properties
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.TrainingSessionUpdateRequest do
  @moduledoc "OpenAPI schema: changing a planned session's plan."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.TrainingFields

  OpenApiSpex.schema(
    %{
      title: "TrainingSessionUpdateRequest",
      description: """
      Only the fields present change. `notes: null` clears the notes; no other field can be cleared. The status,
      owners and relationship never change here.
      """,
      type: :object,
      additionalProperties: false,
      properties: TrainingFields.plan()
    },
    struct?: false
  )
end
