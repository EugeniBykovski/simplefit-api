defmodule SimpleFitWeb.CoachInvitationController do
  @moduledoc """
  The coach's side of invitations (SF-57; ADR 0021 amendment): the coach
  data rules, inviting by email, listing, resending and cancelling. Every
  action acts for the session's own user; the rules live in
  `SimpleFit.Coaching`.
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
  @invitation {"The invitation", "application/json", Schemas.CoachInvitationResponse}
  @invitation_id %Parameter{
    name: :invitation_id,
    in: :path,
    required: true,
    description: "The invitation.",
    schema: %Schema{type: :string, format: :uuid}
  }

  operation :data_rules,
    operation_id: "getMyCoachDataRules",
    summary: "The coach data rules to acknowledge",
    description: """
    The coach data-rules version the viewer must acknowledge before inviting, when they did, and its approved text
    in `language` (`document`). `document_version` is `null` while no approved version is published (inviting is
    then unavailable).

    * `not_found` - Coach–Fighter sharing is not available, or the viewer has no completed coach profile.
    """,
    security: @security,
    parameters: [
      %Parameter{
        name: :language,
        in: :query,
        required: false,
        description: "The language to present the document text in (the app language).",
        schema: %Schema{type: :string}
      }
    ],
    responses: [
      ok: {"The data rules", "application/json", Schemas.CoachDataRulesResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def data_rules(conn, params) do
    with {:ok, rules} <- Coaching.coach_data_rules(conn.assigns.current_user, params["language"]) do
      conn |> no_store() |> render(:data_rules, rules: rules)
    end
  end

  operation :acknowledge_data_rules,
    operation_id: "acknowledgeMyCoachDataRules",
    summary: "Acknowledge the coach data rules",
    description: """
    Records that the viewer acknowledged the published coach data-rules version in the language they were shown
    (separate from account consents and the coach profile), with its evidence. Idempotent: the first
    acknowledgement is kept.

    * `conflict` - `document_version` is not the current version (details `document_version: stale`), or
      `document_language` has no approved text (`document_language: unavailable`).
    * `validation_error` - `document_version` or `document_language` missing.
    * `not_found` - sharing is not enabled, no version is configured, or no completed coach profile.
    """,
    security: @security,
    request_body:
      {"The version shown", "application/json", Schemas.CoachDataRulesAcknowledgeRequest,
       required: true},
    responses: [
      ok: {"The data rules", "application/json", Schemas.CoachDataRulesResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def acknowledge_data_rules(conn, _params) do
    with {:ok, rules} <-
           Coaching.acknowledge_coach_data_rules(conn.assigns.current_user, conn.body_params) do
      conn |> no_store() |> render(:data_rules, rules: rules)
    end
  end

  operation :create,
    operation_id: "createMyCoachInvitation",
    summary: "Invite someone to connect",
    description: """
    Invites an email address to connect with the viewer as their coach and sends E08 with a one-time link
    (14 days). Creates no account, profile or relationship: only the recipient, signed in with that address,
    can accept. A pending invitation of the viewer to the same address is returned unchanged (`200`, no new
    email). Answers the same whether or not the address has an account.

    * `conflict` - the coach data rules are not acknowledged (`data_rules_acknowledgement: required`), or 50
      invitations are pending (`pending_invitations: limit_reached`).
    * `not_found` - sharing is not enabled, no disclosure version is configured, or no completed coach profile.
    * `validation_error` - `email` missing, malformed or the viewer's own; `message` too long or not one plain
      paragraph; any other field.
    * `rate_limited` - per coach (10/hour, 30/day), per recipient (3/day) or per client (20 per 10 minutes).
    """,
    security: @security,
    request_body:
      {"The invitation", "application/json", Schemas.CoachInvitationCreateRequest, required: true},
    responses: [
      created: @invitation,
      ok: @invitation,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error"),
      service_unavailable: ApiSpec.error_response("service_unavailable")
    ]

  def create(conn, _params) do
    with {:ok, invitation, outcome} <-
           Coaching.invite(conn.assigns.current_user, conn.body_params, ClientIP.limit_key(conn)) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:show, invitation: invitation)
    end
  end

  operation :index,
    operation_id: "listMyCoachInvitations",
    summary: "My invitations",
    description: """
    The viewer's invitations, newest first, with masked recipient addresses.

    * `not_found` - sharing is not enabled, or no completed coach profile.
    * `validation_error` - `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
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
        description: "`next_cursor` of the previous page.",
        schema: %Schema{type: :string}
      }
    ],
    responses: [
      ok: {"One page of invitations", "application/json", Schemas.CoachInvitationList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <-
           Coaching.list_invitations(
             conn.assigns.current_user,
             Map.take(params, ["limit", "cursor"])
           ) do
      conn |> no_store() |> render(:index, page: page)
    end
  end

  operation :resend,
    operation_id: "resendMyCoachInvitation",
    summary: "Send an invitation again",
    description: """
    Sends a pending invitation again with a new one-time link and a new 14-day expiry; the previous link stops
    working at once. At most 3 resends, 60 seconds apart.

    * `conflict` - not pending (accepted, declined, cancelled or expired), or no resend left
      (`resends: limit_reached`).
    * `rate_limited` - within 60 seconds of the last send, or the coach's hourly limit.
    * `not_found` - unknown or someone else's invitation, sharing not enabled, or no completed coach profile.
    """,
    security: @security,
    parameters: [@invitation_id],
    responses: [
      ok: @invitation,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error"),
      service_unavailable: ApiSpec.error_response("service_unavailable")
    ]

  def resend(conn, %{"invitation_id" => id}) do
    with {:ok, invitation} <-
           Coaching.resend_invitation(conn.assigns.current_user, id, ClientIP.limit_key(conn)) do
      conn |> no_store() |> render(:show, invitation: invitation)
    end
  end

  operation :cancel,
    operation_id: "cancelMyCoachInvitation",
    summary: "Cancel an invitation",
    description: """
    Cancels a pending invitation: its link stops working. Idempotent for an invitation already cancelled or
    expired. Also available while Coach–Fighter sharing is not enabled.

    * `conflict` - already accepted or declined.
    * `not_found` - unknown or someone else's invitation, or no completed coach profile.
    """,
    security: @security,
    parameters: [@invitation_id],
    responses: [
      no_content: "Cancelled (or already cancelled or expired)",
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel(conn, %{"invitation_id" => id}) do
    with :ok <- Coaching.cancel_invitation(conn.assigns.current_user, id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
