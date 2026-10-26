defmodule SimpleFitWeb.EntryController do
  @moduledoc """
  Post-authentication entry resolution (ADR 0017): the semantic destination
  for the session's own user. Read-only; the rules live in `SimpleFit.Entry`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Parameter, Schema}
  alias SimpleFit.Entry
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Entry"]

  operation :show,
    operation_id: "resolveMyEntry",
    summary: "Where to go next",
    description: """
    Resolves where the authenticated user should go next, as a semantic destination that each client maps to its
    own route (never a path). The answer is derived from current state on every call and resolving writes nothing,
    so repeated and concurrent calls are safe and advance on their own as registration and onboarding complete.

    Order (ADR 0017 as amended by SF-51): mandatory account registration first; then an explicit `intent`
    (`fighter` / `coach` lead to that profile's home when completed, otherwise to its onboarding, whatever the
    other profile's state; `gym` by the viewer's real gym workspaces (SF-84): none - `gym_onboarding` to start
    setup (nothing is created); only the draft they own - `gym_onboarding` resuming it; one completed gym -
    `gym_home`; several - the remembered gym, or `gym_selection`; `sponsor` to its entry point); then a requested
    `context` that names a completed profile, or `context=gym&gym_id=` naming a completed gym where the viewer is
    active staff; otherwise the default by completed contexts (completed profiles and completed gyms): none -
    resume the one journey in progress (an onboarding, or the viewer's draft gym) or choose (`role_selection`, or
    `context_selection` when several are in progress); one - its home; several - the last context chosen with
    `chooseMyEntryContext` while still valid, or `context_selection`. `intent`, `context` and `gym_id` are
    navigation only and grant nothing; `capabilities` (`GYM_WORKSPACE` from an active staff membership at a
    completed gym) is a routing projection, and every gym operation authorizes the gym in its own path. A gym id
    the viewer cannot use is ignored, never reported.

    * `validation_error` - `intent` or `context` is not an allowed value (`invalid_choice`); `gym_id` is not a
      UUID, missing with `context=gym` (`required`) or sent without it.
    """,
    security: [%{"bearerAuth" => []}],
    parameters: [
      %Parameter{
        name: :intent,
        in: :query,
        required: false,
        description: "The journey the user explicitly tried to enter. Omit when there is none.",
        schema: %Schema{type: :string, enum: Enum.map(Entry.intents(), &Atom.to_string/1)}
      },
      %Parameter{
        name: :context,
        in: :query,
        required: false,
        description: """
        An application context to open. Used only when that profile is completed (otherwise ignored, and it never
        starts onboarding); ignored when `intent` is present. Never stored: see `chooseMyEntryContext`.
        """,
        schema: %Schema{type: :string, enum: Enum.map(Entry.contexts(), &Atom.to_string/1)}
      },
      %Parameter{
        name: :gym_id,
        in: :query,
        required: false,
        description:
          "With `context=gym`: the gym workspace to open. Ignored unless the viewer is active staff there.",
        schema: %Schema{type: :string, format: :uuid}
      }
    ],
    responses: [
      ok: {"The entry destination", "application/json", Schemas.EntryResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, params) do
    with {:ok, entry} <-
           Entry.resolve(
             conn.assigns.current_user,
             Map.take(params, ["intent", "context", "gym_id"])
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> render(:show, entry: entry)
    end
  end

  operation :choose_context,
    operation_id: "chooseMyEntryContext",
    summary: "Remember the application context I chose",
    description: """
    Records an explicit choice among the viewer's completed contexts (a context switcher or the context-selection
    screen): a completed profile, or (`context: gym` with `gym_id`, SF-84) a gym with a completed setup where the
    viewer is active staff. With several completed contexts and no `intent` or `context`, the entry then resolves
    to this context's home. The latest choice replaces the previous one, for the viewer's account on every device
    and session; it is a navigation preference, never an authorization grant: it is re-checked on every
    resolution (a revoked membership or an unavailable gym is ignored), and each request still names its own gym
    in its path, so tabs and devices on different gyms never interfere. Resolving the entry never records a
    choice.

    * `not_found` - no gym `gym_id` where the viewer is active staff (existence is never revealed); nothing is
      recorded.
    * `conflict` - that profile context is not completed, or the gym's setup is a draft
      (`details.setup_status: "draft"`); nothing is recorded.
    * `validation_error` - `context` is missing (`required`) or not an allowed value (`invalid_choice`); `gym_id`
      missing with `context: gym`, sent without it, or not a UUID; any other field is rejected with `invalid`
      under its name.
    """,
    security: [%{"bearerAuth" => []}],
    request_body:
      {"The chosen context", "application/json", Schemas.EntryContextChoiceRequest,
       required: true},
    responses: [
      no_content: "Recorded",
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def choose_context(conn, _params) do
    with {:ok, _choice} <-
           Entry.record_context_choice(conn.assigns.current_user, conn.body_params) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(:no_content, "")
    end
  end
end
