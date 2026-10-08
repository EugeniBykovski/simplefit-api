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
    own route (never a path). The answer is derived from current state on every call: nothing is stored, so
    repeated and concurrent calls are safe and advance on their own as registration and onboarding complete.

    Mandatory account registration wins over everything. `intent` is the journey the user explicitly tried to
    enter (for example a Fighter call to action before signing in); it is navigation only and grants nothing.
    Without an intent no role is assumed: an in-progress Fighter onboarding resumes, a completed one goes home,
    otherwise the user chooses (`role_selection`). `capabilities` projects real backend state for routing and is
    not an authorization grant.

    * `validation_error` - `intent` is not one of the allowed values (`invalid_choice`).
    """,
    security: [%{"bearerAuth" => []}],
    parameters: [
      %Parameter{
        name: :intent,
        in: :query,
        required: false,
        description: "The journey the user explicitly tried to enter. Omit when there is none.",
        schema: %Schema{type: :string, enum: Enum.map(Entry.intents(), &Atom.to_string/1)}
      }
    ],
    responses: [
      ok: {"The entry destination", "application/json", Schemas.EntryResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, params) do
    with {:ok, entry} <- Entry.resolve(conn.assigns.current_user, Map.take(params, ["intent"])) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> render(:show, entry: entry)
    end
  end
end
