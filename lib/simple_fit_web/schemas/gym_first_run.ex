defmodule SimpleFitWeb.Schemas.GymChecklistItem do
  @moduledoc "OpenAPI schema: one item of a gym's setup checklist (SF-90)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.FirstRun

  OpenApiSpex.schema(
    %{
      title: "GymChecklistItem",
      description: """
      One step of the opening-week checklist (SF-82 C7), derived on every read from the gym's own records. No
      client can set it, and finishing or dismissing the introduction never changes it.
      """,
      type: :object,
      additionalProperties: false,
      required: [:key, :status],
      properties: %{
        key: %Schema{
          type: :string,
          enum: Enum.map(FirstRun.checklist_keys(), &Atom.to_string/1),
          description: """
          Stable step keys, in display order: `create_gym` (name, type and primary location, completed with the
          setup), `add_class`, `invite_staff`, `invite_members`, `first_check_in`.
          """
        },
        status: %Schema{
          type: :string,
          enum: ["completed", "available", "coming_later"],
          description: """
          `completed`: a persisted fact of the gym. `available`: the owner can do it now. `coming_later`: its
          feature does not exist yet; show it as coming later, never as missing, and link nowhere.
          """
        }
      },
      example: %{key: "create_gym", status: "completed"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymFirstRun do
  @moduledoc "OpenAPI schema: the owner's first run at a gym and its checklist (SF-90)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymChecklistItem

  @timestamp %Schema{type: :string, format: :"date-time", nullable: true}

  OpenApiSpex.schema(
    %{
      title: "GymFirstRun",
      description: """
      The viewer's (the owner's) introduction to one gym, the same on every client, and the gym's checklist.
      Independent of `setup_status`: neither outcome changes the gym or any checklist item.
      """,
      type: :object,
      additionalProperties: false,
      required: [:gym_id, :status, :started_at, :completed_at, :dismissed_at, :checklist],
      properties: %{
        gym_id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ["unavailable", "not_started", "in_progress", "completed", "dismissed"],
          description: """
          `unavailable`: the gym is a draft (no first run until setup completes). `not_started`: offer it.
          `in_progress`: started on some client and not ended; offer to resume. `completed` / `dismissed`: final;
          never offer it again (replaying the tour is client-only and records nothing).
          """
        },
        started_at: %{
          @timestamp
          | description:
              "When the introduction was started; `null` if never (or dismissed unstarted)."
        },
        completed_at: %{@timestamp | description: "When it was finished; `null` otherwise."},
        dismissed_at: %{
          @timestamp
          | description: "When it was ended or skipped; `null` otherwise."
        },
        checklist: %Schema{type: :array, items: GymChecklistItem}
      },
      example: %{
        gym_id: "0b9d6c43-5bd5-4d39-9f5c-3e1b3c1f8c11",
        status: "not_started",
        started_at: nil,
        completed_at: nil,
        dismissed_at: nil,
        checklist: [
          %{key: "create_gym", status: "completed"},
          %{key: "add_class", status: "coming_later"},
          %{key: "invite_staff", status: "coming_later"},
          %{key: "invite_members", status: "coming_later"},
          %{key: "first_check_in", status: "coming_later"}
        ]
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymFirstRunResponse do
  @moduledoc "OpenAPI schema: one gym first run."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymFirstRun

  OpenApiSpex.schema(
    %{
      title: "GymFirstRunResponse",
      type: :object,
      additionalProperties: false,
      required: [:first_run],
      properties: %{first_run: GymFirstRun}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymFirstRunTransitionRequest do
  @moduledoc "OpenAPI schema: the (empty) body of a first-run transition (SF-90)."

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GymFirstRunTransitionRequest",
      description: """
      No fields: the gym comes from the path and the user from the session. Any field (a `user_id`, a checklist
      flag) answers `422 validation_error`.
      """,
      type: :object,
      additionalProperties: false,
      properties: %{}
    },
    struct?: false
  )
end
