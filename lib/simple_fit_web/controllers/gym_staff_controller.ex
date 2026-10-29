defmodule SimpleFitWeb.GymStaffController do
  @moduledoc """
  A gym's staff (SF-93; ADR 0026): the roster, role changes and the end of a
  membership (removal or leaving). Every action acts for the session's own
  user on the gym named in the path; the rules live in `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.GymStaffJSON

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

  @staff_membership_id %Parameter{
    name: :staff_membership_id,
    in: :path,
    required: true,
    description: "An active staff membership of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never
    revealed); for a membership, also an unknown, ended or other gym's membership.
  """

  operation :index,
    operation_id: "listGymStaff",
    summary: "A gym's staff",
    description: """
    The gym's active staff (`status=active`, the default; every staff role) or its ended memberships
    (`status=ended`; owner and managers), oldest membership first. Each entry carries only gym facts and a
    short name.

    #{@access}
    * `forbidden` - `status=ended` for a coach or front desk.
    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
      @gym_id,
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "`active` (default) or `ended`.",
        schema: %Schema{type: :string, enum: ["active", "ended"]}
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
      ok: {"One page of staff", "application/json", Schemas.GymStaffList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <- Gyms.list_staff(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:index, page: page)
    end
  end

  operation :update,
    operation_id: "changeGymStaffRole",
    summary: "Change a staff member's role",
    description: """
    Within the fixed matrix: the owner sets any manager, coach or front desk to `manager`, `coach` or
    `front_desk`; a manager only switches coaches and front desk between those two. Nobody changes their own
    role, nobody becomes `owner` (ownership moves only by a transfer) and the owner's membership never changes.
    The same role again changes nothing. Pending invitations the member can no longer issue are cancelled.
    Takes effect on the member's next request; their session is untouched.

    #{@access}
    * `forbidden` - the viewer's role may not make this change (including their own role).
    * `conflict` - the target is the owner (`details.staff_membership: "owner_requires_transfer"`).
    * `validation_error` - `role` missing or not one of the three, or any other field.
    * `rate_limited` - 60 staff administration requests per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @staff_membership_id],
    request_body:
      {"The new role", "application/json", Schemas.GymStaffRoleChangeRequest, required: true},
    responses: [
      ok: {"The membership", "application/json", Schemas.GymStaffMemberResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update(conn, %{"gym_id" => gym_id, "staff_membership_id" => membership_id}) do
    with {:ok, member} <-
           Gyms.change_staff_role(
             conn.assigns.current_user,
             gym_id,
             membership_id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:show, member: member)
    end
  end

  operation :delete,
    operation_id: "endGymStaffMembership",
    summary: "Remove a staff member, or leave the gym",
    description: """
    Ends an active staff membership at once: another member's (removal: the owner removes any manager, coach
    or front desk, a manager only coaches and front desk) or the viewer's own (leaving: managers, coaches and
    front desk). The owner is never removed and never leaves; ownership moves only by a transfer. The member
    loses every permission at this gym on their next request (`404`), the gym leaves their workspaces, and the
    pending invitations their membership issued are cancelled. Other gyms and their session are untouched;
    the ended membership stays in the gym's history. A repeat answers `404` (the membership is no longer
    active).

    #{@access}
    * `forbidden` - the viewer's role may not remove this member.
    * `conflict` - the target is the owner (`details.staff_membership: "owner_requires_transfer"`).
    * `rate_limited` - 60 staff administration requests per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @staff_membership_id],
    responses: [
      ok: {"The ended membership", "application/json", Schemas.GymStaffMemberResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def delete(conn, %{"gym_id" => gym_id, "staff_membership_id" => membership_id}) do
    user = conn.assigns.current_user

    with {:ok, ended} <- Gyms.end_staff_membership(user, gym_id, membership_id) do
      conn |> no_store() |> render(:ended, membership: ended, viewer_id: user.id)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
