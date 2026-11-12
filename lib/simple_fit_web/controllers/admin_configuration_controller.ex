defmodule SimpleFitWeb.AdminConfigurationController do
  @moduledoc """
  Operator configuration governance (SF-128): the registered feature switches, one
  runtime flag with its history, and two typed actions (suspend, restore) through the
  SF-111 framework. There is no generic configuration write, no environment or secret
  editor, no environment parameter (changes apply to this deployment only) and no way
  to enable a feature beyond its deployment. The rules live in `SimpleFit.Operators`
  and `SimpleFit.Configuration`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.AdminConfigurationJSON

  tags ["Platform operators"]

  @security [%{"bearerAuth" => []}]
  @flag_id [flag_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]]

  @access """
  * `not_found` - not a usable operator (indistinguishable from an unknown route), or no such flag.
  * `enrollment_required`, `forbidden` (permission), `step_up_required` (key check).
  """

  @action """
  Needs `config.flags.write` and a fresh key check, and a one-time `confirmation_token` from a preview of
  exactly this request (same operator, session, flag, revision and reason), with `reason_code`,
  `expected_revision` and `operation_id` (a repeat of the same request returns the current state and changes
  nothing).
  * `conflict` - `details.status`: the flag is already in that state.
  * `revision_conflict` - the flag changed since `expected_revision`: preview again.
  * `confirmation_required`, `confirmation_invalid` - missing, expired, used or for another request.
  """

  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @action_errors @base ++
                   [
                     unprocessable_entity: ApiSpec.error_response("validation_error"),
                     conflict: ApiSpec.error_response("conflict"),
                     precondition_required: ApiSpec.error_response("confirmation_required"),
                     too_many_requests: ApiSpec.error_response("rate_limited")
                   ]

  @preview_ok {"Preview", "application/json", Schemas.OperatorActionPreviewResponse}
  @flag_ok {"The flag", "application/json", Schemas.AdminConfigurationFlagResponse}

  operation :index,
    operation_id: "getAdminConfiguration",
    summary: "The configuration inventory",
    description:
      "Needs `config.read` and a key check. Every registered switch with its environment variable, consumer, " <>
        "control, risk, deployment value, suspension and effective value; the newest changes.\n\n" <>
        @access,
    security: @security,
    responses:
      [ok: {"Inventory", "application/json", Schemas.AdminConfigurationResponse}] ++ @base

  def index(conn, _params) do
    with {:ok, configuration} <- Operators.configuration(user(conn), session(conn), ctx()) do
      conn |> no_store() |> render(:index, configuration: configuration)
    end
  end

  operation :show,
    operation_id: "getAdminRuntimeFlag",
    summary: "One runtime flag and its history",
    description: "Needs `config.read` and a key check.\n\n" <> @access,
    security: @security,
    parameters: @flag_id,
    responses: [ok: @flag_ok] ++ @base

  def show(conn, %{"flag_id" => id}) do
    with {:ok, flag} <- Operators.configuration_flag(user(conn), session(conn), id, ctx()) do
      conn |> no_store() |> render(:show, flag: flag)
    end
  end

  operation :preview_suspend,
    operation_id: "previewSuspendRuntimeFlag",
    summary: "Preview: suspend a feature",
    description:
      "Needs `config.flags.write` and a fresh key check. Changes nothing (no value, cache or consumer); " <>
        "returns the current and proposed state, the impact and a one-time confirmation.\n\n" <>
        @access,
    security: @security,
    parameters: @flag_id,
    request_body:
      {"Action", "application/json", Schemas.SuspendRuntimeFlagRequest, required: true},
    responses: [ok: @preview_ok] ++ @action_errors

  def preview_suspend(conn, %{"flag_id" => id} = params),
    do: preview(conn, "config.flag.suspend", id, params)

  operation :suspend,
    operation_id: "suspendRuntimeFlag",
    summary: "Suspend a feature",
    description:
      "`active` -> `suspended`: the consumer sees the feature off on its next check, in every instance, " <>
        "whatever the deployment says. Not retroactive.\n\n" <> @action <> @access,
    security: @security,
    parameters: @flag_id,
    request_body:
      {"Action", "application/json", Schemas.SuspendRuntimeFlagRequest, required: true},
    responses: [ok: @flag_ok] ++ @action_errors

  def suspend(conn, %{"flag_id" => id} = params),
    do: execute(conn, "config.flag.suspend", id, params)

  operation :preview_restore,
    operation_id: "previewRestoreRuntimeFlag",
    summary: "Preview: restore a suspended feature",
    description:
      "Needs `config.flags.write` and a fresh key check. Changes nothing; returns the impact and a one-time " <>
        "confirmation.\n\n" <> @access,
    security: @security,
    parameters: @flag_id,
    request_body:
      {"Action", "application/json", Schemas.RestoreRuntimeFlagRequest, required: true},
    responses: [ok: @preview_ok] ++ @action_errors

  def preview_restore(conn, %{"flag_id" => id} = params),
    do: preview(conn, "config.flag.restore", id, params)

  operation :restore,
    operation_id: "restoreRuntimeFlag",
    summary: "Restore a suspended feature",
    description:
      "`suspended` -> `active`: the deployment decides again (a feature it left off stays off).\n\n" <>
        @action <> @access,
    security: @security,
    parameters: @flag_id,
    request_body:
      {"Action", "application/json", Schemas.RestoreRuntimeFlagRequest, required: true},
    responses: [ok: @flag_ok] ++ @action_errors

  def restore(conn, %{"flag_id" => id} = params),
    do: execute(conn, "config.flag.restore", id, params)

  defp preview(conn, action_id, id, params) do
    with {:ok, preview} <-
           Operators.preview(action_id, user(conn), session(conn), id, body(params), ctx()) do
      conn |> put_view(json: SimpleFitWeb.OperatorJSON) |> render(:preview, preview: preview)
    end
  end

  defp execute(conn, action_id, id, params) do
    with {:ok, flag} <-
           Operators.execute(action_id, user(conn), session(conn), id, body(params), ctx()) do
      conn |> no_store() |> render(:show, flag: flag)
    end
  end

  defp body(params), do: Map.drop(params, ["flag_id", "format"])
  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
