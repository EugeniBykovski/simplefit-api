defmodule SimpleFitWeb.OperatorAdminController do
  @moduledoc """
  Operator administration and the operator audit log (SF-110, ADR 0028). Reads need
  `operators.read` or `audit.read` and a key check of this session; every write
  needs `operators.manage` and a fresh key check, is refused against oneself, takes
  a reason code and is idempotent per operation id. There is no endpoint for the
  founder bootstrap. The rules live in `SimpleFit.Operators`.
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
        "named by user id. The new operator is `pending_enrollment` and holds exactly the listed permissions.\n\n" <>
        @access <> @write,
    security: @security,
    request_body: {"Provisioning", "application/json", Schemas.ProvisionOperatorRequest},
    responses: [ok: @summary] ++ @base ++ @write_errors

  def provision(conn, params) do
    with {:ok, summary} <- Operators.provision(user(conn), session(conn), params, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  operation :grant,
    operation_id: "grantOperatorPermission",
    summary: "Grant a permission",
    description:
      "Needs `operators.manage` and a fresh key check. Never to oneself.\n\n" <> @access <> @write,
    security: @security,
    parameters: @operator_id,
    request_body: {"Grant", "application/json", Schemas.GrantOperatorPermissionRequest},
    responses: [ok: @summary] ++ @base ++ @write_errors

  def grant(conn, %{"operator_id" => id} = params) do
    with {:ok, summary} <- Operators.grant(user(conn), session(conn), id, params, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  operation :revoke_grant,
    operation_id: "revokeOperatorPermission",
    summary: "Revoke a permission",
    description:
      "Needs `operators.manage` and a fresh key check. Never one's own.\n\n" <> @access <> @write,
    security: @security,
    parameters:
      @operator_id ++ [permission: [in: :path, schema: %Schema{type: :string}, required: true]],
    request_body: {"Reason", "application/json", Schemas.OperatorActionRequest},
    responses: [ok: @summary] ++ @base ++ @write_errors

  def revoke_grant(conn, %{"operator_id" => id, "permission" => permission} = params) do
    with {:ok, summary} <-
           Operators.revoke_grant(user(conn), session(conn), id, permission, params, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  operation :suspend,
    operation_id: "suspendOperator",
    summary: "Suspend an operator",
    description:
      "Needs `operators.manage` and a fresh key check. Never oneself. Active operators only. Ends their key checks.\n\n" <>
        @access <> @write,
    security: @security,
    parameters: @operator_id,
    request_body: {"Reason", "application/json", Schemas.OperatorActionRequest},
    responses: [ok: @summary] ++ @base ++ @write_errors

  def suspend(conn, %{"operator_id" => id} = params) do
    with {:ok, summary} <- Operators.suspend(user(conn), session(conn), id, params, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  operation :reinstate,
    operation_id: "reinstateOperator",
    summary: "Reinstate an operator",
    description:
      "Needs `operators.manage` and a fresh key check. Never oneself. Suspended operators only. With fewer keys than required they return to `pending_enrollment`.\n\n" <>
        @access <> @write,
    security: @security,
    parameters: @operator_id,
    request_body: {"Reason", "application/json", Schemas.OperatorActionRequest},
    responses: [ok: @summary] ++ @base ++ @write_errors

  def reinstate(conn, %{"operator_id" => id} = params) do
    with {:ok, summary} <- Operators.reinstate(user(conn), session(conn), id, params, ctx()) do
      render(conn, :operator, summary: summary)
    end
  end

  operation :revoke,
    operation_id: "revokeOperator",
    summary: "Revoke an operator",
    description:
      "Needs `operators.manage` and a fresh key check. Never oneself. Final. Their permissions, keys and key checks end in the same transaction.\n\n" <>
        @access <> @write,
    security: @security,
    parameters: @operator_id,
    request_body: {"Reason", "application/json", Schemas.OperatorActionRequest},
    responses: [ok: @summary] ++ @base ++ @write_errors

  def revoke(conn, %{"operator_id" => id} = params) do
    with {:ok, summary} <- Operators.revoke(user(conn), session(conn), id, params, ctx()) do
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

  operation :audit_events,
    operation_id: "listOperatorAuditEvents",
    summary: "Operator audit log",
    description: "Needs `audit.read`. Newest first; `before` pages back.\n\n" <> @access,
    security: @security,
    parameters: [
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 100},
        required: false
      ],
      before: [in: :query, schema: %Schema{type: :string, format: :"date-time"}, required: false]
    ],
    responses:
      [ok: {"Events", "application/json", Schemas.OperatorAuditEventListResponse}] ++
        @base ++ [unprocessable_entity: ApiSpec.error_response("validation_error")]

  def audit_events(conn, params) do
    with {:ok, events} <- Operators.list_audit_events(user(conn), session(conn), params, ctx()) do
      render(conn, :audit_events, events: events)
    end
  end

  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
