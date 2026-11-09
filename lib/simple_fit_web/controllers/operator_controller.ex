defmodule SimpleFitWeb.OperatorController do
  @moduledoc """
  The viewer's own operator state, security keys and key check (SF-110, ADR 0028).
  Anyone without a usable operator gets `not_found` on every path, the same answer
  as an unknown route. The rules live in `SimpleFit.Operators`.
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

  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @concealed """
  * `not_found` - the account isn't an operator, or the operator is suspended or revoked (indistinguishable).
  """

  operation :me,
    operation_id: "getCurrentOperator",
    summary: "The viewer's operator state",
    description:
      "Status, permissions (while active), security keys and this session's key check.\n\n" <>
        @concealed,
    security: @security,
    responses: @base ++ [ok: {"The operator", "application/json", Schemas.OperatorSelfResponse}]

  def me(conn, _params) do
    with {:ok, view} <- Operators.me(conn.assigns.current_user, conn.assigns.current_session) do
      render(conn, :me, view: view)
    end
  end

  operation :credentials,
    operation_id: "listOperatorCredentials",
    summary: "The viewer's security keys",
    description: "Metadata only.\n\n" <> @concealed,
    security: @security,
    responses: @base ++ [ok: {"Keys", "application/json", Schemas.OperatorCredentialListResponse}]

  def credentials(conn, _params) do
    with {:ok, list} <-
           Operators.list_credentials(conn.assigns.current_user, conn.assigns.current_session) do
      render(conn, :credentials, credentials: list)
    end
  end

  operation :registration_options,
    operation_id: "createOperatorCredentialOptions",
    summary: "Start registering a security key",
    description:
      "A one-time challenge for this session. A `pending_enrollment` operator may register with their session " <>
        "alone, until enrolment expires; an active operator needs a fresh key check.\n\n" <>
        @concealed <>
        "* `step_up_required` - an active operator without a fresh key check.\n" <>
        "* `conflict` - `details.enrollment: \"expired\"`.\n* `rate_limited` - 20 challenges per hour.\n" <>
        "* `service_unavailable` - WebAuthn isn't configured.",
    security: @security,
    responses:
      @base ++
        [
          ok: {"Options", "application/json", Schemas.WebAuthnOptionsResponse},
          forbidden: ApiSpec.error_response("step_up_required"),
          conflict: ApiSpec.error_response("conflict"),
          too_many_requests: ApiSpec.error_response("rate_limited"),
          service_unavailable: ApiSpec.error_response("service_unavailable")
        ]

  def registration_options(conn, _params) do
    with {:ok, options} <- Operators.registration_options(user(conn), session(conn), ctx()) do
      render(conn, :options, options: options)
    end
  end

  operation :register,
    operation_id: "registerOperatorCredential",
    summary: "Register a security key",
    description:
      "Verifies the registration response (origin, relying party, user verification) and stores the public " <>
        "key. Syncable credentials are refused. The challenge is spent even if verification fails. Reaching " <>
        "the required number of keys activates a `pending_enrollment` operator.\n\n" <>
        @concealed <>
        "* `security_key_rejected` - verification failed, or the challenge is unknown, spent or expired.\n" <>
        "* `conflict` - `details.credential: \"already_registered\"` or `details.enrollment: \"expired\"`.",
    security: @security,
    request_body:
      {"Registration response", "application/json", Schemas.RegisterOperatorCredentialRequest},
    responses:
      @base ++
        [
          created: {"Registered", "application/json", Schemas.OperatorCredentialRegistered},
          forbidden: ApiSpec.error_response("step_up_required"),
          conflict: ApiSpec.error_response("conflict"),
          unprocessable_entity: ApiSpec.error_response("security_key_rejected"),
          service_unavailable: ApiSpec.error_response("service_unavailable")
        ]

  def register(conn, params) do
    with {:ok, result} <- Operators.register_credential(user(conn), session(conn), params, ctx()) do
      conn |> put_status(:created) |> render(:registered, result: result)
    end
  end

  operation :revoke_credential,
    operation_id: "revokeOperatorCredential",
    summary: "Revoke one of the viewer's security keys",
    description:
      "Needs a fresh key check. Refused below the required number of keys: register a replacement first.\n\n" <>
        @concealed <>
        "* `step_up_required`.\n* `conflict` - `details.credentials: \"minimum_required\"`.",
    security: @security,
    parameters: [
      credential_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses:
      @base ++
        [
          ok: {"Revoked", "application/json", Schemas.OperatorCredentialResponse},
          forbidden: ApiSpec.error_response("step_up_required"),
          conflict: ApiSpec.error_response("conflict")
        ]

  def revoke_credential(conn, %{"credential_id" => id}) do
    with {:ok, credential} <-
           Operators.revoke_own_credential(user(conn), session(conn), id, ctx()) do
      render(conn, :credential_show, credential: credential)
    end
  end

  operation :step_up_options,
    operation_id: "createOperatorStepUpOptions",
    summary: "Start a security-key check",
    description:
      "A one-time challenge for this session, listing the operator's keys.\n\n" <>
        @concealed <>
        "* `enrollment_required` - security keys aren't registered yet.\n* `rate_limited` - 20 per hour.\n" <>
        "* `service_unavailable` - WebAuthn isn't configured.",
    security: @security,
    responses:
      @base ++
        [
          ok: {"Options", "application/json", Schemas.WebAuthnOptionsResponse},
          forbidden: ApiSpec.error_response("enrollment_required"),
          too_many_requests: ApiSpec.error_response("rate_limited"),
          service_unavailable: ApiSpec.error_response("service_unavailable")
        ]

  def step_up_options(conn, _params) do
    with {:ok, options} <- Operators.step_up_options(user(conn), session(conn), ctx()) do
      render(conn, :options, options: options)
    end
  end

  operation :verify_step_up,
    operation_id: "verifyOperatorStepUp",
    summary: "Complete a security-key check",
    description:
      "Verifies the assertion (origin, relying party, user verification, signature counter) and records a " <>
        "check bound to this session only. Another session, a sign-out or a suspension ends it.\n\n" <>
        @concealed <>
        "* `enrollment_required`.\n* `security_key_rejected` - verification failed, or the challenge is unknown, " <>
        "spent or expired.\n* `rate_limited` - 30 per hour.",
    security: @security,
    request_body: {"Assertion", "application/json", Schemas.VerifyOperatorStepUpRequest},
    responses:
      @base ++
        [
          ok: {"Verified", "application/json", Schemas.OperatorStepUpResponse},
          forbidden: ApiSpec.error_response("enrollment_required"),
          unprocessable_entity: ApiSpec.error_response("security_key_rejected"),
          too_many_requests: ApiSpec.error_response("rate_limited"),
          service_unavailable: ApiSpec.error_response("service_unavailable")
        ]

  def verify_step_up(conn, params) do
    with {:ok, step_up} <- Operators.verify_step_up(user(conn), session(conn), params, ctx()) do
      render(conn, :step_up_show, step_up: step_up)
    end
  end

  operation :end_step_up,
    operation_id: "endOperatorStepUp",
    summary: "End this session's security-key check",
    description: "Used when leaving the Control Plane. Idempotent.\n\n" <> @concealed,
    security: @security,
    responses: @base ++ [no_content: "Ended"]

  def end_step_up(conn, _params) do
    with :ok <- Operators.end_step_up(user(conn), session(conn), ctx()) do
      send_resp(conn, :no_content, "")
    end
  end

  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
