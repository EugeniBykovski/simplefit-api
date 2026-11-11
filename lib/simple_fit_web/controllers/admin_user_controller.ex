defmodule SimpleFitWeb.AdminUserController do
  @moduledoc """
  Operator account administration (SF-122): exact search, one account, revealing its
  addresses, and three typed actions (suspend, lift the suspension, sign out
  everywhere) through the SF-111 framework. There is no generic update, no list of
  accounts and no "act as user". The rules live in `SimpleFit.Operators`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.AdminUserJSON

  tags ["Platform operators"]

  @security [%{"bearerAuth" => []}]
  @user_id [user_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]]
  @reason [
    reason_code: [
      in: :query,
      required: true,
      description: "Why the operator reads this account; recorded with the read.",
      schema: %Schema{type: :string, enum: Operators.user_read_reasons()}
    ]
  ]

  @access """
  * `not_found` - not a usable operator (indistinguishable from an unknown route), or no such account.
  * `enrollment_required`, `forbidden` (permission), `step_up_required` (key check).
  * `validation_error` - a missing or unknown `reason_code`, or a malformed query.
  """

  @action """
  Needs a one-time `confirmation_token` from a preview of exactly this request (same operator, session,
  account, revision and reason), with `reason_code`, `expected_revision` and `operation_id` (a repeat of the
  same request returns the current state and changes nothing).
  * `conflict` - `details.target: "self"` (the operator's own account), `details.target: "operator"` (a
    platform operator's account: use operator administration), or `details.status`.
  * `revision_conflict` - the account changed since `expected_revision`.
  * `confirmation_required`, `confirmation_invalid` - missing, expired, used or for another request.
  """

  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    unprocessable_entity: ApiSpec.error_response("validation_error"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @action_errors @base ++
                   [
                     conflict: ApiSpec.error_response("conflict"),
                     precondition_required: ApiSpec.error_response("confirmation_required"),
                     too_many_requests: ApiSpec.error_response("rate_limited")
                   ]

  @preview_ok {"Preview", "application/json", Schemas.OperatorActionPreviewResponse}
  @state_ok {"The account's state", "application/json", Schemas.AdminUserStateResponse}

  operation :search,
    operation_id: "searchAdminUsers",
    summary: "Find one account by exact email or user id",
    description:
      """
      Needs `users.read` and a key check. Exact only: a full email address (case-insensitive) or a user id;
      never part of either, never a list. At most one account, with masked addresses. Every search is
      recorded with its `reason_code` (`user.searched`), found or not; 60 per operator and hour.

      """ <> @access <> "* `rate_limited` - too many searches.",
    security: @security,
    parameters:
      [
        query: [
          in: :query,
          required: true,
          description: "An exact email address or user id.",
          schema: %Schema{type: :string, minLength: 1, maxLength: 320}
        ]
      ] ++ @reason,
    responses:
      [
        ok: {"At most one account", "application/json", Schemas.AdminUserSearchResponse},
        too_many_requests: ApiSpec.error_response("rate_limited")
      ] ++ @base

  def search(conn, params) do
    with {:ok, result} <-
           Operators.search_users(
             user(conn),
             session(conn),
             Map.take(params, ~w(query reason_code)),
             ctx()
           ) do
      render(conn, :search, users: result.users)
    end
  end

  operation :show,
    operation_id: "getAdminUser",
    summary: "One account",
    description:
      "Needs `users.read` and a key check. Recorded with its `reason_code` (`user.viewed`).\n\n" <>
        @access,
    security: @security,
    parameters: @user_id ++ @reason,
    responses: [ok: {"The account", "application/json", Schemas.AdminUserResponse}] ++ @base

  def show(conn, %{"user_id" => id} = params) do
    with {:ok, user} <-
           Operators.get_user(
             user(conn),
             session(conn),
             id,
             Map.take(params, ["reason_code"]),
             ctx()
           ) do
      render(conn, :show, user: user)
    end
  end

  operation :reveal_email,
    operation_id: "revealAdminUserEmail",
    summary: "Show an account's full email addresses",
    description:
      "Needs `users.reveal_email` and a fresh key check. Recorded with its `reason_code` " <>
        "(`user.email_revealed`) before the addresses are returned.\n\n" <> @access,
    security: @security,
    parameters: @user_id,
    request_body: {"Reason", "application/json", Schemas.AdminUserReadRequest, required: true},
    responses: [ok: {"Addresses", "application/json", Schemas.AdminUserEmailResponse}] ++ @base

  def reveal_email(conn, %{"user_id" => id} = params) do
    with {:ok, email} <-
           Operators.reveal_user_email(
             user(conn),
             session(conn),
             id,
             Map.take(params, ["reason_code"]),
             ctx()
           ) do
      render(conn, :email, email: email)
    end
  end

  operation :preview_suspend,
    operation_id: "previewSuspendAdminUser",
    summary: "Preview: suspend an account",
    description:
      "Needs `users.restrict` and a fresh key check. Changes nothing; returns the impact and a one-time " <>
        "confirmation.\n\n" <> @access,
    security: @security,
    parameters: @user_id,
    request_body: {"Action", "application/json", Schemas.SuspendUserRequest, required: true},
    responses: [ok: @preview_ok] ++ @action_errors

  def preview_suspend(conn, %{"user_id" => id} = params),
    do: preview(conn, "user.suspend", id, params)

  operation :suspend,
    operation_id: "suspendAdminUser",
    summary: "Suspend an account",
    description:
      "Needs `users.restrict` and a fresh key check. `active` -> `suspended`: every session is revoked and no identity (email code, Google, Apple) can sign in until the suspension is lifted. Data, profiles and memberships stay as they are.\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @user_id,
    request_body: {"Action", "application/json", Schemas.SuspendUserRequest, required: true},
    responses: [ok: @state_ok] ++ @action_errors

  def suspend(conn, %{"user_id" => id} = params), do: execute(conn, "user.suspend", id, params)

  operation :preview_lift_suspension,
    operation_id: "previewLiftSuspensionAdminUser",
    summary: "Preview: lift an account's suspension",
    description:
      "Needs `users.restrict` and a fresh key check. Changes nothing; returns the impact and a one-time " <>
        "confirmation.\n\n" <> @access,
    security: @security,
    parameters: @user_id,
    request_body:
      {"Action", "application/json", Schemas.LiftUserSuspensionRequest, required: true},
    responses: [ok: @preview_ok] ++ @action_errors

  def preview_lift_suspension(conn, %{"user_id" => id} = params),
    do: preview(conn, "user.lift_suspension", id, params)

  operation :lift_suspension,
    operation_id: "liftSuspensionAdminUser",
    summary: "Lift an account's suspension",
    description:
      "Needs `users.restrict` and a fresh key check. `suspended` -> `active`: sign-in works again. Revoked sessions stay revoked.\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @user_id,
    request_body:
      {"Action", "application/json", Schemas.LiftUserSuspensionRequest, required: true},
    responses: [ok: @state_ok] ++ @action_errors

  def lift_suspension(conn, %{"user_id" => id} = params),
    do: execute(conn, "user.lift_suspension", id, params)

  operation :preview_sign_out_everywhere,
    operation_id: "previewSignOutEverywhereAdminUser",
    summary: "Preview: sign an account out everywhere",
    description:
      "Needs `users.sessions.revoke` and a fresh key check. Changes nothing; returns the impact and a one-time " <>
        "confirmation.\n\n" <> @access,
    security: @security,
    parameters: @user_id,
    request_body:
      {"Action", "application/json", Schemas.SignOutUserEverywhereRequest, required: true},
    responses: [ok: @preview_ok] ++ @action_errors

  def preview_sign_out_everywhere(conn, %{"user_id" => id} = params),
    do: preview(conn, "user.sign_out_everywhere", id, params)

  operation :sign_out_everywhere,
    operation_id: "signOutEverywhereAdminUser",
    summary: "Sign an account out everywhere",
    description:
      "Needs `users.sessions.revoke` and a fresh key check. Revokes every active session; the next request with any of them is refused. The account can sign in again.\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @user_id,
    request_body:
      {"Action", "application/json", Schemas.SignOutUserEverywhereRequest, required: true},
    responses: [ok: @state_ok] ++ @action_errors

  def sign_out_everywhere(conn, %{"user_id" => id} = params),
    do: execute(conn, "user.sign_out_everywhere", id, params)

  defp preview(conn, action_id, id, params) do
    with {:ok, preview} <-
           Operators.preview(action_id, user(conn), session(conn), id, body(params), ctx()) do
      conn |> put_view(json: SimpleFitWeb.OperatorJSON) |> render(:preview, preview: preview)
    end
  end

  defp execute(conn, action_id, id, params) do
    with {:ok, state} <-
           Operators.execute(action_id, user(conn), session(conn), id, body(params), ctx()) do
      render(conn, :state, user: state)
    end
  end

  defp body(params), do: Map.drop(params, ["user_id", "format"])
  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
