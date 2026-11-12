defmodule SimpleFitWeb.OperatorAdminController do
  @moduledoc """
  Operator administration and the operator audit log (SF-110, ADR 0028; admin
  actions SF-111, ADR 0029). Reads need `operators.read` or `audit.read` and a key
  check of this session; every write needs `operators.manage` and a fresh key check,
  is refused against oneself, takes a reason code and is idempotent per operation
  id. The declared admin actions also take the expected revision and, where
  required, the confirmation of their preview. Each route names its action: there
  is no generic execute. There is no endpoint for the founder bootstrap. The rules
  live in `SimpleFit.Operators`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.OperatorJSON

  tags ["Platform operators"]

  @security [%{"bearerAuth" => []}]
  @operator_id [
    operator_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
  ]

  @access """
  * `not_found` - the viewer isn't a usable operator (indistinguishable from an unknown route), or no such
    operator.
  * `enrollment_required` - the viewer's security keys aren't registered yet.
  * `forbidden` - the permission isn't granted.
  * `step_up_required` - no key check in this session, or not fresh enough for this action.
  """

  @write """
  * `conflict` - `details.target: "self"`; `details.status`, `details.permission`, `details.operator`,
    `details.user` or `details.operation_id` name the conflict.
  * `validation_error` - a malformed reason code, operation id or permission.
  """

  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @summary {"The operator", "application/json", Schemas.OperatorSummaryResponse}
  @write_errors [
    conflict: ApiSpec.error_response("conflict"),
    unprocessable_entity: ApiSpec.error_response("validation_error")
  ]

  operation :index,
    operation_id: "listOperators",
    summary: "List operators",
    description: "Needs `operators.read`.\n\n" <> @access,
    security: @security,
    responses: [ok: {"Operators", "application/json", Schemas.OperatorListResponse}] ++ @base

  def index(conn, _params) do
    with {:ok, list} <- Operators.list_operators(user(conn), session(conn), ctx()) do
      render(conn, :operators, summaries: list)
    end
  end

  operation :permissions,
    operation_id: "listOperatorPermissions",
    summary: "The operator permission catalog",
    description:
      "Needs `operators.read`. Every permission with the key check it needs; no role or bundle exists.\n\n" <>
        @access,
    security: @security,
    responses:
      [ok: {"Catalog", "application/json", Schemas.OperatorPermissionCatalogResponse}] ++ @base

  def permissions(conn, _params) do
    with {:ok, catalog} <- Operators.permission_catalog(user(conn), session(conn), ctx()) do
      render(conn, :permissions, catalog: catalog)
    end
  end

  operation :show,
    operation_id: "getOperator",
    summary: "One operator",
    description: "Needs `operators.read`.\n\n" <> @access,
    security: @security,
    parameters: @operator_id,
    responses: [ok: @summary] ++ @base

  def show(conn, %{"operator_id" => id}) do
    with {:ok, summary} <- Operators.get_operator(user(conn), session(conn), id, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  operation :provision,
    operation_id: "provisionOperator",
    summary: "Provision an operator",
    description:
      "Needs `operators.manage` and a fresh key check. For an existing account with completed registration, " <>
        "named by its user id or exact email address. The new operator is `pending_enrollment` and holds exactly the listed permissions.\n\n" <>
        @access <> @write,
    security: @security,
    request_body: {"Provisioning", "application/json", Schemas.ProvisionOperatorRequest},
    responses: [ok: @summary] ++ @base ++ @write_errors

  def provision(conn, params) do
    with {:ok, summary} <- Operators.provision(user(conn), session(conn), params, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  @action """
  An admin action (SF-111, ADR 0029): needs `operators.manage` and a fresh key check, never targets
  oneself, takes a reason code from this action's list, the operator's `expected_revision` and an
  `operation_id`. Repeating the same request with the same `operation_id` changes nothing and answers
  with the current state.

  * `revision_conflict` (409) - the operator changed since `expected_revision`; `details.current_revision`.
  * `conflict` (409) - `details.target: "self"`, or the state (`details.status`, `details.permission`,
    `details.operator`, `details.operation_id`).
  * `confirmation_required` (428) - the action needs the `confirmation_token` of its preview.
  * `confirmation_invalid` (422) - the token doesn't match this operator, session, action, target,
    parameters and revision, expired, or was used.
  * `validation_error` (422) - a reason code not in this action's list, or a malformed field.
  """

  @preview """
  Previews an admin action (SF-111): the current and proposed state, the impact and what it needs,
  checked as execution would be. Changes nothing, sends nothing. When the action needs confirmation the
  answer carries a one-time `confirmation.token` (two minutes), bound to this operator, session, action,
  target, reason and revision. A preview authorizes nothing later: execution checks everything again.
  """

  @action_errors [
    conflict: ApiSpec.error_response("conflict"),
    unprocessable_entity: ApiSpec.error_response("validation_error"),
    precondition_required: ApiSpec.error_response("confirmation_required"),
    too_many_requests: ApiSpec.error_response("rate_limited")
  ]

  @preview_ok {"Preview", "application/json", Schemas.OperatorActionPreviewResponse}
  @permission_path [permission: [in: :path, schema: %Schema{type: :string}, required: true]]

  operation :preview_grant,
    operation_id: "previewGrantOperatorPermission",
    summary: "Preview granting a permission",
    description: @preview <> "\n\n" <> @access,
    security: @security,
    parameters: @operator_id,
    request_body:
      {"Preview", "application/json", Schemas.GrantOperatorPermissionPreviewRequest,
       required: true},
    responses: [ok: @preview_ok] ++ @base ++ @action_errors

  def preview_grant(conn, %{"operator_id" => id} = params),
    do: preview(conn, "operator.permission.grant", id, params)

  operation :grant,
    operation_id: "grantOperatorPermission",
    summary: "Grant a permission",
    description:
      "Needs confirmation (`previewGrantOperatorPermission`). Never to oneself.\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @operator_id,
    request_body:
      {"Grant", "application/json", Schemas.GrantOperatorPermissionRequest, required: true},
    responses: [ok: @summary] ++ @base ++ @action_errors

  def grant(conn, %{"operator_id" => id} = params),
    do: execute(conn, "operator.permission.grant", id, params)

  operation :preview_revoke_grant,
    operation_id: "previewRevokeOperatorPermission",
    summary: "Preview revoking a permission",
    description: @preview <> "\n\n" <> @access,
    security: @security,
    parameters: @operator_id ++ @permission_path,
    request_body:
      {"Preview", "application/json", Schemas.RevokeOperatorPermissionPreviewRequest,
       required: true},
    responses: [ok: @preview_ok] ++ @base ++ @action_errors

  def preview_revoke_grant(conn, %{"operator_id" => id, "permission" => permission} = params),
    do: preview(conn, "operator.permission.revoke", id, Map.put(params, "permission", permission))

  operation :revoke_grant,
    operation_id: "revokeOperatorPermission",
    summary: "Revoke a permission",
    description:
      "Narrows access only, so no confirmation is needed. Never one's own.\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @operator_id ++ @permission_path,
    request_body:
      {"Revocation", "application/json", Schemas.RevokeOperatorPermissionRequest, required: true},
    responses: [ok: @summary] ++ @base ++ @action_errors

  def revoke_grant(conn, %{"operator_id" => id, "permission" => permission} = params),
    do: execute(conn, "operator.permission.revoke", id, Map.put(params, "permission", permission))

  operation :preview_suspend,
    operation_id: "previewSuspendOperator",
    summary: "Preview suspending an operator",
    description: @preview <> "\n\n" <> @access,
    security: @security,
    parameters: @operator_id,
    request_body:
      {"Preview", "application/json", Schemas.SuspendOperatorPreviewRequest, required: true},
    responses: [ok: @preview_ok] ++ @base ++ @action_errors

  def preview_suspend(conn, %{"operator_id" => id} = params),
    do: preview(conn, "operator.suspend", id, params)

  operation :suspend,
    operation_id: "suspendOperator",
    summary: "Suspend an operator",
    description:
      "Needs confirmation (`previewSuspendOperator`). Active operators only; ends their key checks.\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @operator_id,
    request_body:
      {"Suspension", "application/json", Schemas.SuspendOperatorRequest, required: true},
    responses: [ok: @summary] ++ @base ++ @action_errors

  def suspend(conn, %{"operator_id" => id} = params),
    do: execute(conn, "operator.suspend", id, params)

  operation :preview_reinstate,
    operation_id: "previewReinstateOperator",
    summary: "Preview reinstating an operator",
    description: @preview <> "\n\n" <> @access,
    security: @security,
    parameters: @operator_id,
    request_body:
      {"Preview", "application/json", Schemas.ReinstateOperatorPreviewRequest, required: true},
    responses: [ok: @preview_ok] ++ @base ++ @action_errors

  def preview_reinstate(conn, %{"operator_id" => id} = params),
    do: preview(conn, "operator.reinstate", id, params)

  operation :reinstate,
    operation_id: "reinstateOperator",
    summary: "Reinstate an operator",
    description:
      "Needs confirmation (`previewReinstateOperator`). Suspended operators only; with fewer keys than required they return to `pending_enrollment`.\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @operator_id,
    request_body:
      {"Reinstatement", "application/json", Schemas.ReinstateOperatorRequest, required: true},
    responses: [ok: @summary] ++ @base ++ @action_errors

  def reinstate(conn, %{"operator_id" => id} = params),
    do: execute(conn, "operator.reinstate", id, params)

  operation :preview_revoke,
    operation_id: "previewRevokeOperator",
    summary: "Preview revoking an operator",
    description: @preview <> "\n\n" <> @access,
    security: @security,
    parameters: @operator_id,
    request_body:
      {"Preview", "application/json", Schemas.RevokeOperatorPreviewRequest, required: true},
    responses: [ok: @preview_ok] ++ @base ++ @action_errors

  def preview_revoke(conn, %{"operator_id" => id} = params),
    do: preview(conn, "operator.revoke", id, params)

  operation :revoke,
    operation_id: "revokeOperator",
    summary: "Revoke an operator",
    description:
      "Needs confirmation (`previewRevokeOperator`). Final: their permissions, keys and key checks end in the same transaction.\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @operator_id,
    request_body:
      {"Revocation", "application/json", Schemas.RevokeOperatorRequest, required: true},
    responses: [ok: @summary] ++ @base ++ @action_errors

  def revoke(conn, %{"operator_id" => id} = params),
    do: execute(conn, "operator.revoke", id, params)

  defp preview(conn, action_id, id, params) do
    with {:ok, preview} <-
           Operators.preview(action_id, user(conn), session(conn), id, params, ctx()) do
      render(conn, :preview, preview: preview)
    end
  end

  defp execute(conn, action_id, id, params) do
    with {:ok, summary} <-
           Operators.execute(action_id, user(conn), session(conn), id, params, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  operation :revoke_operator_credential,
    operation_id: "revokeOtherOperatorCredential",
    summary: "Revoke another operator's security key",
    description:
      "Needs `operators.manage` and a fresh key check. For a lost or compromised key. With fewer keys than " <>
        "required the operator returns to `pending_enrollment` and must register a replacement.\n\n" <>
        @access <> @write,
    security: @security,
    parameters:
      @operator_id ++
        [
          credential_id: [
            in: :path,
            schema: %Schema{type: :string, format: :uuid},
            required: true
          ]
        ],
    request_body: {"Reason", "application/json", Schemas.OperatorActionRequest},
    responses: [ok: @summary] ++ @base ++ @write_errors

  def revoke_operator_credential(conn, %{"operator_id" => id, "credential_id" => cid} = params) do
    with {:ok, summary} <-
           Operators.revoke_operator_credential(user(conn), session(conn), id, cid, params, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  @uuid %Schema{type: :string, format: :uuid}
  @code %Schema{type: :string, pattern: "^[a-z][a-z0-9_.]{1,79}$"}
  @time %Schema{type: :string, format: :"date-time"}

  operation :audit_events,
    operation_id: "listOperatorAuditEvents",
    summary: "Operator audit log",
    description:
      "Needs `audit.read`. Newest first, in a stable order (time, then id). Filters compare for equality; " <>
        "`occurred_after` is inclusive, `occurred_before` exclusive. Follow `next_cursor` with the same " <>
        "filters; a cursor is refused (`validation_error`, `cursor`) with other filters, for another operator, " <>
        "when altered or after an hour. `before` (time) can't be combined with `cursor`. Each query is audited.\n\n" <>
        @access,
    security: @security,
    parameters: [
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 100},
        required: false
      ],
      cursor: [in: :query, schema: %Schema{type: :string, maxLength: 1024}, required: false],
      before: [in: :query, schema: @time, required: false],
      actor_operator_id: [in: :query, schema: @uuid, required: false],
      action: [in: :query, schema: @code, required: false],
      command: [in: :query, schema: @code, required: false],
      target_type: [
        in: :query,
        schema: %Schema{type: :string, pattern: "^[a-z][a-z0-9_]{1,39}$"},
        required: false
      ],
      target_id: [in: :query, schema: @uuid, required: false],
      outcome: [
        in: :query,
        schema: %Schema{
          type: :string,
          enum: ["allowed", "refused", "conflict", "invalid", "failed"]
        },
        required: false
      ],
      occurred_after: [in: :query, schema: @time, required: false],
      occurred_before: [in: :query, schema: @time, required: false]
    ],
    responses:
      [ok: {"Events", "application/json", Schemas.OperatorAuditEventListResponse}] ++
        @base ++ [unprocessable_entity: ApiSpec.error_response("validation_error")]

  def audit_events(conn, params) do
    with {:ok, page} <- Operators.list_audit_events(user(conn), session(conn), params, ctx()) do
      render(conn, :audit_events, page: page)
    end
  end

  operation :audit_event,
    operation_id: "getOperatorAuditEvent",
    summary: "One operator audit event",
    description: "Needs `audit.read`. Each view is audited.\n\n" <> @access,
    security: @security,
    parameters: [event_id: [in: :path, schema: @uuid, required: true]],
    responses: [ok: {"Event", "application/json", Schemas.OperatorAuditEventResponse}] ++ @base

  def audit_event(conn, %{"event_id" => id}) do
    with {:ok, event} <- Operators.get_audit_event(user(conn), session(conn), id, ctx()) do
      render(conn, :audit_event, event: event)
    end
  end

  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
