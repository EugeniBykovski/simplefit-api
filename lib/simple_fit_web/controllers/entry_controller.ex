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
    other profile's state; `gym` / `sponsor` to their entry points); then a requested `context` that names a
    completed profile; otherwise the default by completed profiles: none - resume the one onboarding in progress
    or choose (`role_selection`, or `context_selection` when both are in progress); one - its home; both - the
    last context chosen with `chooseMyEntryContext`, or `context_selection`. `intent` and `context` are navigation
    only and grant nothing; `capabilities` projects completed profiles for routing and is not an authorization
    grant.

    * `validation_error` - `intent` or `context` is not one of the allowed values (`invalid_choice`).
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
           Entry.resolve(conn.assigns.current_user, Map.take(params, ["intent", "context"])) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> render(:show, entry: entry)
    end
  end

  operation :choose_context,
    operation_id: "chooseMyEntryContext",
    summary: "Remember the application context I chose",
    description: """
    Records an explicit choice between the viewer's completed profile contexts (a context switcher or the
    context-selection screen). With both Fighter and Coach completed and no `intent` or `context`, the entry then
    resolves to this context's home. Only a completed context can be chosen; the latest choice replaces the
    previous one, from any device. A navigation preference, never an authorization grant: it is re-checked on
    every resolution. Resolving the entry never records a choice.

    * `conflict` - that profile context is not completed; nothing is recorded.
    * `validation_error` - `context` is missing (`required`) or not an allowed value (`invalid_choice`); any
      other field is rejected with `invalid` under its name.
    """,
    security: [%{"bearerAuth" => []}],
    request_body:
      {"The chosen context", "application/json", Schemas.EntryContextChoiceRequest,
       required: true},
    responses: [
      no_content: "Recorded",
      unauthorized: ApiSpec.error_response("unauthorized"),
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
