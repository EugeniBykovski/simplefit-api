defmodule SimpleFitWeb.GymStaffInvitationController do
  @moduledoc """
  A gym's staff invitations (SF-93; ADR 0026 D-G12, D-G16): invite, list,
  resend and cancel. Every action acts for the session's own user on the gym
  named in the path; the rules live in `SimpleFit.Gyms`. No token ever
  appears in a response: it exists only in the E06 email's link fragment.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, ClientIP, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.StaffInvitationJSON

  tags ["Gym staff"]

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

  @invitation_id %Parameter{
    name: :invitation_id,
    in: :path,
    required: true,
    description: "A staff invitation of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never
    revealed); for an invitation, also an unknown id or another gym's invitation.
  """

  @invitation {"The invitation", "application/json", Schemas.GymStaffInvitationResponse}

  operation :create,
    operation_id: "createGymStaffInvitation",
    summary: "Invite someone to the gym's staff",
    description: """
    Invites an email address to a role and queues the E06 email, whose link carries a one-time token in its
    fragment (`<web app>/invite/staff#token=…`). The invitation grants nothing: the recipient must sign in with
    that address (a verified email identity) and accept it explicitly, within 7 days. Creating it creates no
    account and reveals nothing about one. Only a completed gym invites. The owner invites managers, coaches
    and front desk; a manager coaches and front desk; nobody is invited as owner.

    The same address and role while an invitation is pending returns that invitation with `200` (no new email):
    a repeated request is safe. Another gym inviting the same address is independent.

    #{@access}
    * `forbidden` - the viewer's role may not invite (or not this role: managers are invited by the owner).
    * `conflict` - the gym is a draft (`details.setup_status: "draft"`); this address has a pending invitation
      to another role (`details.staff_invitation: "pending_other_role"`: cancel it first); or it belongs to an
      active member of this gym (`details.staff_membership: "already_active"`).
    * `validation_error` - `email` invalid or the viewer's own, `role` missing or not `manager`, `coach` or
      `front_desk`, or any other field.
    * `rate_limited` - 10 invitations per hour and 30 per day per user, 100 per day per gym, 3 per day per
      address (any gym), 20 per 10 minutes per client, in rolling windows; repeats are not counted.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"Who and which role", "application/json", Schemas.GymStaffInvitationCreateRequest,
       required: true},
    responses: [
      created: @invitation,
      ok:
        {"The pending invitation for this address and role", "application/json",
         Schemas.GymStaffInvitationResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error"),
      service_unavailable: ApiSpec.error_response("service_unavailable")
    ]

  def create(conn, %{"gym_id" => gym_id}) do
    with {:ok, invitation, outcome} <-
           Gyms.create_staff_invitation(
             conn.assigns.current_user,
             gym_id,
             conn.body_params,
             ClientIP.limit_key(conn)
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:gym_show, invitation: invitation)
    end
  end

  operation :index,
    operation_id: "listGymStaffInvitations",
    summary: "A gym's staff invitations",
    description: """
    The gym's invitations, newest first, with their effective status and a masked address. Owner and managers.

    #{@access}
    * `forbidden` - a coach or front desk.
    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
      @gym_id,
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "Only invitations with this effective status.",
        schema: %Schema{
          type: :string,
          enum: ["pending", "accepted", "declined", "cancelled", "expired"]
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
      ok: {"One page of invitations", "application/json", Schemas.GymStaffInvitationList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <- Gyms.list_staff_invitations(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:gym_index, page: page)
    end
  end

  operation :resend,
    operation_id: "resendGymStaffInvitation",
    summary: "Send a staff invitation again",
    description: """
    Sends a pending invitation again with a new token (the previous link stops working at once) and a new
    7-day expiry. At most 3 resends, 60 seconds apart. The same permission as inviting that role.

    #{@access}
    * `forbidden` - the viewer's role may not invite this role.
    * `conflict` - not pending (`details.staff_invitation: "not_pending"`) or no resends left
      (`details.resends: "limit_reached"`).
    * `rate_limited` - within 60 seconds of the last sending, or 60 staff administration requests per 10
      minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @invitation_id],
    responses: [
      ok: @invitation,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error"),
      service_unavailable: ApiSpec.error_response("service_unavailable")
    ]

  def resend(conn, %{"gym_id" => gym_id, "invitation_id" => invitation_id}) do
    with {:ok, invitation} <-
           Gyms.resend_staff_invitation(conn.assigns.current_user, gym_id, invitation_id) do
      conn |> no_store() |> render(:gym_show, invitation: invitation)
    end
  end

  operation :cancel,
    operation_id: "cancelGymStaffInvitation",
    summary: "Cancel a staff invitation",
    description: """
    A pending invitation can no longer be accepted. Repeating it, or cancelling an expired invitation, returns
    the invitation unchanged. The same permission as inviting that role.

    #{@access}
    * `forbidden` - the viewer's role may not invite this role.
    * `conflict` - already accepted or declined (`details.staff_invitation: "accepted" | "declined"`).
    * `rate_limited` - 60 staff administration requests per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @invitation_id],
    responses: [
      ok: @invitation,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel(conn, %{"gym_id" => gym_id, "invitation_id" => invitation_id}) do
    with {:ok, invitation} <-
           Gyms.cancel_staff_invitation(conn.assigns.current_user, gym_id, invitation_id) do
      conn |> no_store() |> render(:gym_show, invitation: invitation)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
