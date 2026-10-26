defmodule SimpleFitWeb.GymController do
  @moduledoc """
  Gyms (ADR 0026; SF-83): create a draft gym, list the viewer's gyms and read
  one gym. Every action acts for the session's own user; the gym comes only
  from the path, and the rules live in `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, ClientIP, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Gyms"]

  @security [%{"bearerAuth" => []}]

  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{
                   "retry-after" => %Header{
                     description: "Seconds until another request is accepted.",
                     schema: %Schema{type: :integer}
                   }
                 }}

  @gym_id %Parameter{
    name: :gym_id,
    in: :path,
    required: true,
    description: "The gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  operation :create,
    operation_id: "createGym",
    summary: "Create a draft gym",
    description: """
    Creates a draft gym with the viewer as its owner, atomically (the gym and the owner's staff membership commit
    together). Requires completed account registration; no other profile or capability. Nothing is public and
    no plan, payment or verification is involved.

    `client_request_id` makes the create idempotent: repeating it returns the same gym with `200` and creates
    nothing. While the viewer has an open draft, any create returns that draft with `200` (the request's fields
    are ignored): one open draft per user. There is no limit on completed gyms.

    * `validation_error` - a field is missing, invalid or unknown (owners, roles and statuses are never
      accepted), or account registration is incomplete (`account_registration: required`).
    * `conflict` - `client_request_id` names a gym where the viewer is no longer staff
      (`details.client_request_id: "reused"`).
    * `rate_limited` - more than 5 gym creations per user, or 20 per client, in any rolling 24 hours;
      `retry-after` is when the oldest counted creation leaves the window. Replays, resumed drafts and refused
      attempts are not counted.
    """,
    security: @security,
    request_body: {"The gym", "application/json", Schemas.GymCreateRequest, required: true},
    responses: [
      created: {"Created", "application/json", Schemas.GymResponse},
      ok:
        {"The gym of this client_request_id, or the open draft", "application/json",
         Schemas.GymResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create(conn, _params) do
    with {:ok, gym, outcome} <-
           Gyms.create_gym(conn.assigns.current_user, conn.body_params, ClientIP.limit_key(conn)) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:show, gym: gym)
    end
  end

  operation :index,
    operation_id: "listMyGyms",
    summary: "My gyms",
    description: """
    The gyms where the viewer holds an active staff membership, with their role and permissions there, newest
    membership first. Only the viewer's own memberships are read; nothing is selected or remembered.

    * `validation_error` - `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
      %Parameter{
        name: :limit,
        in: :query,
        required: false,
        description: "Page size (1–100, default 50).",
        schema: %Schema{type: :integer, minimum: 1, maximum: 100}
      },
      %Parameter{
        name: :cursor,
        in: :query,
        required: false,
        description: "The `next_cursor` of the previous page.",
        schema: %Schema{type: :string}
      }
    ],
    responses: [
      ok: {"One page of gyms", "application/json", Schemas.GymList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <-
           Gyms.list_my_gyms(conn.assigns.current_user, Map.take(params, ["limit", "cursor"])) do
      conn |> no_store() |> render(:index, page: page)
    end
  end

  operation :show,
    operation_id: "getGym",
    summary: "One gym",
    description: """
    One gym, for one of its active staff: the gym, its locations and the viewer's role and permissions there.

    * `not_found` - no such gym, or the viewer holds no active staff membership there (the existence of a gym is
      never revealed to anyone else).
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: {"The gym", "application/json", Schemas.GymResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"gym_id" => gym_id}) do
    with {:ok, gym} <- Gyms.get_gym(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:show, gym: gym)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
