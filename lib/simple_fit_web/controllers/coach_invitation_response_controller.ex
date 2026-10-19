defmodule SimpleFitWeb.CoachInvitationResponseController do
  @moduledoc """
  The recipient's side of coach invitations (SF-57; ADR 0021 amendment):
  the anonymous preview of a link, the signed-in recipient's explicit
  acceptance or decline, and the recipient's inbox (SF-73). The token travels only in request bodies (the E08
  link carries it in the URL fragment, which browsers never send). The rules
  live in `SimpleFit.Coaching`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Coaching
  alias SimpleFitWeb.{ApiSpec, ClientIP, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Coaching"]

  @security [%{"bearerAuth" => []}]
  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{
                   "retry-after" => %Header{
                     description: "Seconds until another request is accepted.",
                     schema: %Schema{type: :integer}
                   }
                 }}

  operation :index,
    operation_id: "listMyIncomingCoachInvitations",
    summary: "Invitations addressed to me",
    description: """
    The invitations sent to any email identity the viewer verified with a code, newest first, with the coach's
    public identity and note and the effective status. Matched on the server from the session's user: no
    address, user id or provider email is accepted, and Google or Apple sign-ins without an email identity have
    an empty inbox. Nothing here is a relationship (see `listMyCoaches`); respond with the invitation link
    (`acceptCoachInvitation`, `declineCoachInvitation`) or by id (`acceptMyIncomingCoachInvitation`,
    `declineMyIncomingCoachInvitation`). Other query parameters are ignored.

    * `not_found` - Coach–Fighter sharing is not enabled (distinct from an empty inbox).
    * `validation_error` - `account_registration` `required`, or `limit`, `cursor` or `status` invalid.
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
        description: "Page size, 1-100 (default 50).",
        schema: %Schema{type: :integer, minimum: 1, maximum: 100, default: 50}
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
      ok: {"One page of invitations", "application/json", Schemas.IncomingCoachInvitationList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <-
           Coaching.list_incoming_invitations(
             conn.assigns.current_user,
             Map.take(params, ["limit", "cursor", "status"])
           ) do
      conn |> no_store() |> render(:index, page: page)
    end
  end

  operation :preview,
    operation_id: "previewCoachInvitation",
    summary: "What an invitation link shows",
    description: """
    No sign-in needed: the inviting coach's public identity and note, the expiry and the disclosure the recipient
    would accept. Reveals nothing about the recipient or any account. Every token that is not a current pending
    one (unknown, resent, accepted, declined, cancelled or expired) answers the same `410
    invitation_unavailable`.

    * `not_found` - Coach–Fighter sharing is not enabled.
    * `rate_limited` - 30 responses per 10 minutes per client, shared with accept and decline.
    """,
    request_body:
      {"The token", "application/json", Schemas.CoachInvitationTokenRequest, required: true},
    responses: [
      ok: {"The invitation", "application/json", Schemas.CoachInvitationPreview},
      not_found: ApiSpec.error_response("not_found"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def preview(conn, _params) do
    with {:ok, preview} <-
           Coaching.preview_invitation(conn.body_params["token"], ClientIP.limit_key(conn)) do
      conn |> no_store() |> render(:preview, preview: preview)
    end
  end

  operation :accept,
    operation_id: "acceptCoachInvitation",
    summary: "Accept an invitation",
    description: """
    The explicit acceptance. The viewer must be signed in with the invited address (an email identity they
    verified), have completed account registration and a fighter profile, and echo exactly the disclosure version
    shown by `previewCoachInvitation`. In one transaction the invitation is consumed and the relationship becomes
    active with that disclosure; nothing changes if any step fails. A token works once: a repeated acceptance
    answers `410` (see `listMyCoaches`).

    * `invitation_unavailable` (410) - not a current pending invitation, or the viewer's own.
    * `invitation_recipient_mismatch` (403) - the viewer is not signed in with the invited address.
    * `validation_error` - `account_registration` or `fighter_profile` `required`, or `disclosure_version`
      missing.
    * `conflict` - `disclosure_version` is not the current version (details `disclosure_version: stale`).
    * `not_found` - Coach–Fighter sharing is not enabled.
    * `rate_limited` - 30 per 10 minutes per client.
    """,
    security: @security,
    request_body:
      {"The acceptance", "application/json", Schemas.CoachInvitationAcceptRequest, required: true},
    responses: [
      ok: {"The relationship", "application/json", Schemas.CoachInvitationAcceptResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("invitation_recipient_mismatch"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def accept(conn, _params) do
    with {:ok, result} <-
           Coaching.accept_invitation(
             conn.assigns.current_user,
             conn.body_params,
             ClientIP.limit_key(conn)
           ) do
      conn |> no_store() |> render(:accept, result: result)
    end
  end

  operation :decline,
    operation_id: "declineCoachInvitation",
    summary: "Decline an invitation",
    description: """
    The explicit decline: by the viewer signed in with the invited address and with a completed fighter profile.
    Creates nothing; the link stops working. Also available while Coach–Fighter sharing is not enabled.

    * `invitation_unavailable` (410), `invitation_recipient_mismatch` (403), `validation_error`
      (`account_registration` / `fighter_profile` `required`) - as for `acceptCoachInvitation`.
    * `rate_limited` - 30 per 10 minutes per client.
    """,
    security: @security,
    request_body:
      {"The token", "application/json", Schemas.CoachInvitationTokenRequest, required: true},
    responses: [
      no_content: "Declined",
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("invitation_recipient_mismatch"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def decline(conn, _params) do
    with :ok <-
           Coaching.decline_invitation(
             conn.assigns.current_user,
             conn.body_params,
             ClientIP.limit_key(conn)
           ) do
      send_resp(conn, :no_content, "")
    end
  end

  @invitation_id %Parameter{
    name: :invitation_id,
    in: :path,
    required: true,
    description: """
    An invitation id from `listMyIncomingCoachInvitations`. Not a credential: only an invitation addressed to
    one of the viewer's verified email identities is ever found.
    """,
    schema: %Schema{type: :string, format: :uuid}
  }

  @by_id_note """
  Located by id among the invitations addressed to the viewer's verified email identities (no token: possession
  of the E08 email is not required, so a valid session is enough; see ADR 0021, SF-73 amendment). A foreign,
  unknown, malformed or no longer pending id answers `410 invitation_unavailable`, the same for all.
  """

  operation :preview_incoming,
    operation_id: "previewMyIncomingCoachInvitation",
    summary: "Review an invitation addressed to me",
    description: """
    #{@by_id_note}
    The coach's public identity and note, the expiry and the disclosure to accept, as `previewCoachInvitation`.

    * `not_found` - Coach–Fighter sharing is not enabled, or responding by id is not available yet (it stays off
      until the 18+ and document-language checks exist).
    * `validation_error` - `account_registration` `required`.
    * `rate_limited` - 30 per 10 minutes per client, shared with the other responses.
    """,
    security: @security,
    parameters: [@invitation_id],
    responses: [
      ok: {"The invitation", "application/json", Schemas.CoachInvitationPreview},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def preview_incoming(conn, %{"invitation_id" => id}) do
    with {:ok, preview} <-
           Coaching.preview_incoming_invitation(
             conn.assigns.current_user,
             id,
             ClientIP.limit_key(conn)
           ) do
      conn |> no_store() |> render(:preview, preview: preview)
    end
  end

  operation :accept_incoming,
    operation_id: "acceptMyIncomingCoachInvitation",
    summary: "Accept an invitation addressed to me",
    description: """
    #{@by_id_note}
    The explicit acceptance, with the same prerequisites and the same single transaction as
    `acceptCoachInvitation`: completed account registration and fighter profile, the exact current disclosure
    version, then the relationship is activated and the invitation consumed together.

    * `not_found` - sharing is not enabled, or responding by id is not available yet.
    * `validation_error` - `account_registration` or `fighter_profile` `required`, or `disclosure_version`
      missing.
    * `conflict` - `disclosure_version` is not the current version (details `disclosure_version: stale`).
    * `rate_limited` - 30 per 10 minutes per client.
    """,
    security: @security,
    parameters: [@invitation_id],
    request_body:
      {"The acceptance", "application/json", Schemas.IncomingCoachInvitationAcceptRequest,
       required: true},
    responses: [
      ok: {"The relationship", "application/json", Schemas.CoachInvitationAcceptResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def accept_incoming(conn, %{"invitation_id" => id}) do
    with {:ok, result} <-
           Coaching.accept_incoming_invitation(
             conn.assigns.current_user,
             id,
             conn.body_params,
             ClientIP.limit_key(conn)
           ) do
      conn |> no_store() |> render(:accept, result: result)
    end
  end

  operation :decline_incoming,
    operation_id: "declineMyIncomingCoachInvitation",
    summary: "Decline an invitation addressed to me",
    description: """
    #{@by_id_note}
    The explicit decline, as `declineCoachInvitation`: a completed fighter profile is required, nothing is
    created, and it also works while Coach–Fighter sharing is not enabled.

    * `validation_error` - `account_registration` or `fighter_profile` `required`.
    * `rate_limited` - 30 per 10 minutes per client.
    """,
    security: @security,
    parameters: [@invitation_id],
    responses: [
      no_content: "Declined",
      unauthorized: ApiSpec.error_response("unauthorized"),
      gone: ApiSpec.error_response("invitation_unavailable"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def decline_incoming(conn, %{"invitation_id" => id}) do
    with :ok <-
           Coaching.decline_incoming_invitation(
             conn.assigns.current_user,
             id,
             ClientIP.limit_key(conn)
           ) do
      send_resp(conn, :no_content, "")
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
