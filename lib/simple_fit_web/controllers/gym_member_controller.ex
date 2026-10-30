defmodule SimpleFitWeb.GymMemberController do
  @moduledoc """
  A gym's members as its staff manage them (SF-95; ADR 0026 D-G07, D-G08):
  the roster, join requests and their approval, removal, the enrollment
  settings (join code, auto-approval) and the member-list dry run. Every
  action acts for the session's own user on the gym named in the path; the
  rules live in `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, Schemas}

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

  @gym_id %Parameter{
    name: :gym_id,
    in: :path,
    required: true,
    description: "The gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @gym_member_id %Parameter{
    name: :gym_member_id,
    in: :path,
    required: true,
    description: "A membership of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @limit %Parameter{
    name: :limit,
    in: :query,
    required: false,
    description: "Page size (1–100, default 50).",
    schema: %Schema{type: :integer, minimum: 1, maximum: 100}
  }

  @cursor %Parameter{
    name: :cursor,
    in: :query,
    required: false,
    description: "`next_cursor` of the previous page (same filters).",
    schema: %Schema{type: :string}
  }

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never
    revealed); for a membership, also an unknown id or another gym's.
  """

  @member {"The membership", "application/json", Schemas.GymMemberResponse}
  @enrollment {"The enrollment settings", "application/json",
               Schemas.GymEnrollmentSettingsResponse}

  operation :index,
    operation_id: "listGymMembers",
    summary: "A gym's members",
    description: """
    The gym's active (default) or ended members, oldest first, with a short name and how they joined: never an
    email, user id, profile or training data. Owner, managers and front desk.

    #{@access}
    * `forbidden` - a coach (a coach's member access is limited to their own classes, which do not exist yet).
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
      @limit,
      @cursor
    ],
    responses: [
      ok: {"One page of members", "application/json", Schemas.GymMemberList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <- Gyms.list_members(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:index, page: page)
    end
  end

  operation :show,
    operation_id: "getGymMember",
    summary: "One membership of a gym",
    description: """
    One membership of this gym in any status (requested, active, rejected, cancelled or ended). Owner, managers
    and front desk.

    #{@access}
    * `forbidden` - a coach.
    """,
    security: @security,
    parameters: [@gym_id, @gym_member_id],
    responses: [
      ok: @member,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"gym_id" => gym_id, "gym_member_id" => member_id}) do
    with {:ok, member} <- Gyms.get_member(conn.assigns.current_user, gym_id, member_id) do
      conn |> no_store() |> render(:show, member: member)
    end
  end

  operation :remove,
    operation_id: "removeGymMember",
    summary: "End a gym membership",
    description: """
    Ends an active membership (`ended`, reason `removed`). The row is kept; the person may join again later.
    Repeating it returns the membership unchanged. Owner and managers.

    #{@access}
    * `forbidden` - a coach or front desk.
    * `conflict` - not active (`details.gym_member: "requested" | "rejected" | "cancelled" | "ended"`).
    * `rate_limited` - 120 member administration requests per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @gym_member_id],
    responses: [
      ok: @member,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def remove(conn, %{"gym_id" => gym_id, "gym_member_id" => member_id}) do
    with {:ok, member} <- Gyms.remove_member(conn.assigns.current_user, gym_id, member_id) do
      conn |> no_store() |> render(:show, member: member)
    end
  end

  operation :requests,
    operation_id: "listGymJoinRequests",
    summary: "A gym's pending join requests",
    description: """
    The join-code requests waiting for a decision, oldest first. Owner, managers and front desk.

    #{@access}
    * `forbidden` - a coach.
    * `validation_error` - `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [@gym_id, @limit, @cursor],
    responses: [
      ok: {"One page of requests", "application/json", Schemas.GymMemberList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def requests(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <- Gyms.list_join_requests(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:index, page: page)
    end
  end

  @decision_errors """
  #{@access}
  * `forbidden` - a coach.
  * `rate_limited` - 120 member administration requests per 10 minutes per user.
  """

  operation :approve,
    operation_id: "approveGymJoinRequest",
    summary: "Approve a join request",
    description: """
    `requested` -> `active`. Repeating it on an active membership returns it unchanged. Owner, managers and
    front desk.

    #{@decision_errors}
    * `conflict` - the request was rejected or cancelled, or the membership ended
      (`details.gym_member: "rejected" | "cancelled" | "ended"`).
    """,
    security: @security,
    parameters: [@gym_id, @gym_member_id],
    responses: [
      ok: @member,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def approve(conn, %{"gym_id" => gym_id, "gym_member_id" => member_id}) do
    with {:ok, member} <- Gyms.approve_join_request(conn.assigns.current_user, gym_id, member_id) do
      conn |> no_store() |> render(:show, member: member)
    end
  end

  operation :reject,
    operation_id: "rejectGymJoinRequest",
    summary: "Reject a join request",
    description: """
    `requested` -> `rejected` (final; the person may send a new request later). Repeating it returns it
    unchanged. Owner, managers and front desk.

    #{@decision_errors}
    * `conflict` - not a pending request (`details.gym_member: "active" | "cancelled" | "ended"`).
    """,
    security: @security,
    parameters: [@gym_id, @gym_member_id],
    responses: [
      ok: @member,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def reject(conn, %{"gym_id" => gym_id, "gym_member_id" => member_id}) do
    with {:ok, member} <- Gyms.reject_join_request(conn.assigns.current_user, gym_id, member_id) do
      conn |> no_store() |> render(:show, member: member)
    end
  end

  operation :enrollment,
    operation_id: "getGymEnrollmentSettings",
    summary: "A gym's enrollment settings",
    description: """
    The join code (to show at the desk or share as `<web app>/join/<code>`) and whether auto-approval is on.
    Owner, managers and front desk; `can_manage` says whether the viewer may change them.

    #{@access}
    * `forbidden` - a coach.
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: @enrollment,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def enrollment(conn, %{"gym_id" => gym_id}) do
    with {:ok, settings} <- Gyms.get_enrollment_settings(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:enrollment, settings: settings)
    end
  end

  @settings_errors """
  #{@access}
  * `forbidden` - a coach or front desk.
  * `conflict` - the gym is a draft (`details.setup_status: "draft"`).
  * `rate_limited` - 120 member administration requests per 10 minutes per user.
  """

  operation :update_enrollment,
    operation_id: "updateGymEnrollmentSettings",
    summary: "Switch a gym's auto-approval",
    description: """
    Turns auto-approval of join-code requests on or off (off by default). Each change is audited; the same value
    again changes nothing. Even when on, a joiner without a completed account and a verified sign-in identity
    gets a request. Owner and managers.

    #{@settings_errors}
    * `validation_error` - `auto_approve` missing or not a boolean, or any other field.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"The setting", "application/json", Schemas.GymEnrollmentSettingsUpdateRequest,
       required: true},
    responses: [
      ok: @enrollment,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update_enrollment(conn, %{"gym_id" => gym_id}) do
    with {:ok, settings} <-
           Gyms.update_enrollment_settings(conn.assigns.current_user, gym_id, conn.body_params) do
      conn |> no_store() |> render(:enrollment, settings: settings)
    end
  end

  operation :rotate_code,
    operation_id: "rotateGymJoinCode",
    summary: "Issue a new join code",
    description: """
    Issues a new join code and enables joining by code; the previous code stops working at once. Owner and
    managers.

    #{@settings_errors}
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: @enrollment,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def rotate_code(conn, %{"gym_id" => gym_id}) do
    with {:ok, settings} <- Gyms.rotate_join_code(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:enrollment, settings: settings)
    end
  end

  operation :disable_code,
    operation_id: "disableGymJoinCode",
    summary: "Turn off joining by code",
    description: """
    Removes the join code: nobody can join by code until a new one is issued. Pending requests stay. Repeating
    it changes nothing. Owner and managers.

    #{@settings_errors}
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: @enrollment,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def disable_code(conn, %{"gym_id" => gym_id}) do
    with {:ok, settings} <- Gyms.disable_join_code(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:enrollment, settings: settings)
    end
  end

  operation :import_preview,
    operation_id: "previewGymMemberImport",
    summary: "Dry-run a member list",
    description: """
    Parses a CSV member list, maps its columns, validates and deduplicates the rows and classifies each against
    this gym's own members, join requests and member invitations. **A dry run: nothing is stored, sent or
    logged.** Committing the list (storing contacts of people without an account, bulk invitations) is not
    available until an approved legal basis and retention rule exist (`commit.available: false`); invite people
    one by one with `createGymMemberInvitation`. No account is created, verified, linked or matched by name.
    Owner, managers and front desk.

    #{@access}
    * `forbidden` - a coach.
    * `conflict` - the gym is a draft (`details.setup_status: "draft"`).
    * `validation_error` - `csv` missing, not UTF-8, empty, too large (1 MB, 1,000 rows, 30 columns, 500 bytes per
      field) or malformed (`fields.csv` names the line); `mapping` names an unknown column or maps two fields to
      one; no column for `email` (`email_column`); any other field.
    * `rate_limited` - 30 previews per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"The list", "application/json", Schemas.GymMemberImportPreviewRequest, required: true},
    responses: [
      ok: {"The preview", "application/json", Schemas.GymMemberImportPreviewResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def import_preview(conn, %{"gym_id" => gym_id}) do
    with {:ok, preview} <-
           Gyms.preview_member_import(conn.assigns.current_user, gym_id, conn.body_params) do
      conn |> no_store() |> render(:import_preview, preview: preview)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
