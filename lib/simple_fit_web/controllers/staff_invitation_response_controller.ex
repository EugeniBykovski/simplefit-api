defmodule SimpleFitWeb.StaffInvitationResponseController do
  @moduledoc """
  The recipient's side of gym staff invitations (SF-93; ADR 0026 D-G16,
  D-G22): the token-free inbox matched by verified email (mobile), answers by
  invitation id, and the web page's preview and answers by the E06 token,
  which travels only in request bodies (the link carries it in the URL
  fragment, which browsers never send). The rules live in `SimpleFit.Gyms`.
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

  @invitation_id %Parameter{
    name: :invitation_id,
    in: :path,
    required: true,
    description: "An invitation from the viewer's inbox.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @token_body {"The token from the E06 link", "application/json",
               Schemas.StaffInvitationTokenRequest, required: true}

  @accept_rules """
  The viewer must be signed in with the invited address (an email identity they verified with a code; a Google
  or Apple sign-in alone does not count: add and verify the address first with `requestEmailIdentityLink`) and
  have completed account registration. Nothing else is needed: no Coach or Fighter profile is required,
  created or changed, and no Coach–Fighter relationship is created. One transaction re-checks the session, the
  invitation and the gym, creates the active staff membership with the invited role, consumes the invitation
  and records the audit events; nothing changes if any step fails. The gym then appears among the viewer's gym
  workspaces; the current context is not switched. Repeating a successful acceptance returns the same
  membership (`outcome: already_accepted`).
  """

  @answer_errors """
  * `validation_error` - `account_registration` `required` (acceptance only).
  * `conflict` - the viewer is already active staff of this gym (`details.staff_membership: "already_active"`);
    the invitation stays pending.
  * `rate_limited` - 30 previews and answers per 10 minutes per client.
  """

  operation :index,
    operation_id: "listMyStaffInvitations",
    summary: "Staff invitations sent to me",
    description: """
    The staff invitations sent to any email address the viewer verified with a code, newest first, with the
    gym's name, the role, the inviter's first name and the effective status. Matched on the server from the
    session's user: no address or user id is accepted, and a Google or Apple sign-in without an email identity
    has an empty inbox. Reading changes nothing. Answer with `acceptMyStaffInvitation` or
    `declineMyStaffInvitation` (no token is needed or shown).

    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
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
      ok: {"One page of invitations", "application/json", Schemas.MyStaffInvitationList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <- Gyms.list_my_staff_invitations(conn.assigns.current_user, params) do
      conn |> no_store() |> render(:my_index, page: page)
    end
  end

  operation :show,
    operation_id: "getMyStaffInvitation",
    summary: "One staff invitation sent to me",
    description: """
    One invitation from the viewer's inbox, in any status (so a client can say it expired, was cancelled or was
    already accepted). Reading changes nothing.

    * `not_found` - an unknown id, or an invitation not sent to one of the viewer's verified addresses.
    """,
    security: @security,
    parameters: [@invitation_id],
    responses: [
      ok: {"The invitation", "application/json", Schemas.MyStaffInvitationResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"invitation_id" => invitation_id}) do
    with {:ok, invitation} <-
           Gyms.get_my_staff_invitation(conn.assigns.current_user, invitation_id) do
      conn |> no_store() |> render(:my_show, invitation: invitation)
    end
  end

  operation :accept_by_id,
    operation_id: "acceptMyStaffInvitation",
    summary: "Accept a staff invitation from my inbox",
    description: """
    The explicit acceptance of an invitation from the inbox, by id (no body). #{@accept_rules}

    * `not_found` - an unknown id, or an invitation not sent to one of the viewer's verified addresses.
    * `invitation_unavailable` (410) - expired, cancelled, declined, or accepted by someone else.
    #{@answer_errors}
    """,
    security: @security,
    parameters: [@invitation_id],
    responses: [
      ok: {"The membership", "application/json", Schemas.StaffInvitationAcceptResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def accept_by_id(conn, %{"invitation_id" => invitation_id}) do
    accept(conn, {:id, invitation_id})
  end

  operation :decline_by_id,
    operation_id: "declineMyStaffInvitation",
    summary: "Decline a staff invitation from my inbox",
    description: """
    Declines an invitation from the inbox, by id (no body). Creates nothing; a repeat returns the same answer.

    * `not_found` - an unknown id, or an invitation not sent to one of the viewer's verified addresses.
    * `invitation_unavailable` (410) - expired, cancelled or accepted.
    * `rate_limited` - 30 previews and answers per 10 minutes per client.
    """,
    security: @security,
    parameters: [@invitation_id],
    responses: [
      ok: {"The declined invitation", "application/json", Schemas.MyStaffInvitationResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def decline_by_id(conn, %{"invitation_id" => invitation_id}) do
    decline(conn, {:id, invitation_id})
  end

  operation :accept_by_token,
    operation_id: "acceptStaffInvitation",
    summary: "Accept a staff invitation link",
    description: """
    The explicit acceptance on the web page of an E06 link, with its token in the body. Holding the token is not
    enough. #{@accept_rules}

    * `invitation_unavailable` (410) - not a current pending token (unknown, resent, used, declined, cancelled
      or expired: one answer for all).
    * `invitation_recipient_mismatch` (403) - the viewer is not signed in with the invited address.
    #{@answer_errors}
    """,
    security: @security,
    request_body: @token_body,
    responses: [
      ok: {"The membership", "application/json", Schemas.StaffInvitationAcceptResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("invitation_recipient_mismatch"),
      conflict: ApiSpec.error_response("conflict"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def accept_by_token(conn, _params), do: accept(conn, {:token, conn.body_params["token"]})

  operation :decline_by_token,
    operation_id: "declineStaffInvitation",
    summary: "Decline a staff invitation link",
    description: """
    Declines on the web page of an E06 link, with its token in the body, for the signed-in recipient. Creates
    nothing.

    * `invitation_unavailable` (410) - not a current pending token.
    * `invitation_recipient_mismatch` (403) - the viewer is not signed in with the invited address.
    * `rate_limited` - 30 previews and answers per 10 minutes per client.
    """,
    security: @security,
    request_body: @token_body,
    responses: [
      ok: {"The declined invitation", "application/json", Schemas.MyStaffInvitationResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("invitation_recipient_mismatch"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def decline_by_token(conn, _params), do: decline(conn, {:token, conn.body_params["token"]})

  operation :preview,
    operation_id: "previewStaffInvitation",
    summary: "What a staff invitation link shows",
    description: """
    No sign-in needed: the gym's name, the role, the inviter's first name and role, and the expiry. Reveals
    nothing about the recipient, the address or any account, and changes nothing. Every token that is not a
    current pending one answers the same `410 invitation_unavailable`.

    * `rate_limited` - 30 previews and answers per 10 minutes per client.
    """,
    request_body: @token_body,
    responses: [
      ok: {"The invitation", "application/json", Schemas.StaffInvitationPreviewResponse},
      gone: ApiSpec.error_response("invitation_unavailable"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def preview(conn, _params) do
    with {:ok, preview} <-
           Gyms.preview_staff_invitation(conn.body_params["token"], ClientIP.limit_key(conn)) do
      conn |> no_store() |> render(:preview, preview: preview)
    end
  end

  defp accept(conn, locator) do
    with {:ok, result} <-
           Gyms.accept_staff_invitation(
             conn.assigns.current_user,
             conn.assigns.current_session,
             locator,
             ClientIP.limit_key(conn)
           ) do
      conn |> no_store() |> render(:accepted, result: result)
    end
  end

  defp decline(conn, locator) do
    with {:ok, invitation} <-
           Gyms.decline_staff_invitation(
             conn.assigns.current_user,
             locator,
             ClientIP.limit_key(conn)
           ) do
      conn |> no_store() |> render(:my_show, invitation: invitation)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
