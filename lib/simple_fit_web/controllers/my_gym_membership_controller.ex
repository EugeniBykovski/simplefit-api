defmodule SimpleFitWeb.MyGymMembershipController do
  @moduledoc """
  The viewer's own gym memberships (SF-95; ADR 0026 D-G07, D-G08): list
  them, join a gym by its code, withdraw a request, leave. Account-scoped:
  the user is the session's, never a parameter. Also the public preview of
  a join code. The rules live in `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, ClientIP, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.GymMemberJSON

  tags ["Gym members"]

  @security [%{"bearerAuth" => []}]

  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{
                   "retry-after" => %Header{
                     description: "Seconds until another request is accepted.",
                     schema: %Schema{type: :integer}
                   }
                 }}

  @gym_member_id %Parameter{
    name: :gym_member_id,
    in: :path,
    required: true,
    description: "One of the viewer's own memberships.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @membership {"The membership", "application/json", Schemas.MyGymMembershipResponse}

  @code_body {"The join code", "application/json", Schemas.GymJoinRequest, required: true}

  operation :index,
    operation_id: "listMyGymMemberships",
    summary: "My gym memberships",
    description: """
    The viewer's memberships of gyms as a participant, in every status (requested, active, rejected, cancelled,
    ended), newest first. Staff memberships are not listed (they are gym workspaces, `listMyGyms`).

    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "Only memberships with this status.",
        schema: %Schema{
          type: :string,
          enum: ["requested", "active", "ended", "rejected", "cancelled"]
        }
      },
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
        description: "`next_cursor` of the previous page (same `status`).",
        schema: %Schema{type: :string}
      }
    ],
    responses: [
      ok: {"One page of memberships", "application/json", Schemas.MyGymMembershipList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <- Gyms.list_my_gym_memberships(conn.assigns.current_user, params) do
      conn |> no_store() |> render(:my_index, page: page)
    end
  end

  operation :show,
    operation_id: "getMyGymMembership",
    summary: "One of my gym memberships",
    description: """
    One of the viewer's memberships in any status.

    * `not_found` - an unknown id or someone else's membership.
    """,
    security: @security,
    parameters: [@gym_member_id],
    responses: [
      ok: @membership,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"gym_member_id" => member_id}) do
    with {:ok, membership} <- Gyms.get_my_gym_membership(conn.assigns.current_user, member_id) do
      conn |> no_store() |> render(:my_show, membership: membership)
    end
  end

  operation :join,
    operation_id: "joinGym",
    summary: "Join a gym by its code",
    description: """
    Sends a join request to the gym of the code: `201` with a `requested` membership that the gym's staff approve
    or reject. Only when the gym has explicitly enabled auto-approval, and the viewer holds a verified sign-in
    identity, is the membership `active` at once (`auto_approved: true`). Needs a completed account and nothing
    else: no Fighter or Coach profile is required, created or changed. A gym membership gives no gym workspace
    or staff permission. While a request is pending, joining again returns it with `200`.

    * `not_found` - an unknown, malformed or disabled code (one answer for all).
    * `conflict` - already an active member (`details.gym_member: "already_active"`).
    * `validation_error` - `account_registration` `required`.
    * `rate_limited` - 20 previews and joins per 10 minutes per client and 10 per user, counted on every attempt.
    """,
    security: @security,
    request_body: @code_body,
    responses: [
      created: @membership,
      ok: {"The pending request", "application/json", Schemas.MyGymMembershipResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def join(conn, _params) do
    with {:ok, membership, outcome} <-
           Gyms.join_gym(
             conn.assigns.current_user,
             conn.assigns.current_session,
             conn.body_params["code"],
             ClientIP.limit_key(conn)
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:my_show, membership: membership)
    end
  end

  operation :cancel,
    operation_id: "cancelMyGymJoinRequest",
    summary: "Withdraw my join request",
    description: """
    `requested` -> `cancelled` (final; a new join sends a new request). Repeating it returns it unchanged.

    * `not_found` - an unknown id or someone else's membership.
    * `conflict` - not a pending request (`details.gym_member: "active" | "rejected" | "ended"`).
    """,
    security: @security,
    parameters: [@gym_member_id],
    responses: [
      ok: @membership,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel(conn, %{"gym_member_id" => member_id}) do
    with {:ok, membership} <-
           Gyms.cancel_gym_join_request(
             conn.assigns.current_user,
             conn.assigns.current_session,
             member_id
           ) do
      conn |> no_store() |> render(:my_show, membership: membership)
    end
  end

  operation :leave,
    operation_id: "leaveGymMembership",
    summary: "Leave a gym",
    description: """
    Ends the viewer's active membership (`ended`, reason `left`). The row is kept; joining again later creates a
    new membership. Repeating it returns it unchanged. Staff memberships at that gym are not affected.

    * `not_found` - an unknown id or someone else's membership.
    * `conflict` - not active (`details.gym_member: "requested" | "rejected" | "cancelled" | "ended"`).
    """,
    security: @security,
    parameters: [@gym_member_id],
    responses: [
      ok: @membership,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def leave(conn, %{"gym_member_id" => member_id}) do
    with {:ok, membership} <-
           Gyms.leave_gym_membership(
             conn.assigns.current_user,
             conn.assigns.current_session,
             member_id
           ) do
      conn |> no_store() |> render(:my_show, membership: membership)
    end
  end

  operation :preview,
    operation_id: "previewGymJoin",
    summary: "What a join code shows",
    description: """
    No sign-in needed: the gym's name and whether joining needs the gym's approval. Changes nothing.

    * `not_found` - an unknown, malformed or disabled code (one answer for all).
    * `rate_limited` - 20 previews and joins per 10 minutes per client.
    """,
    request_body: @code_body,
    responses: [
      ok: {"The gym", "application/json", Schemas.GymJoinPreviewResponse},
      not_found: ApiSpec.error_response("not_found"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def preview(conn, _params) do
    with {:ok, preview} <-
           Gyms.preview_gym_join(conn.body_params["code"], ClientIP.limit_key(conn)) do
      conn |> no_store() |> render(:join_preview, preview: preview)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
