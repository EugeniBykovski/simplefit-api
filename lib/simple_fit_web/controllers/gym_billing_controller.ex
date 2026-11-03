defmodule SimpleFitWeb.GymBillingController do
  @moduledoc """
  SimpleFit's SaaS plans and a gym's subscription to one (SF-101; ADR 0026):
  the published catalog, the gym's subscription intent and cancellation, and
  its entitlement projection. No endpoint activates a subscription, takes a
  payment or writes the catalog (an operator task does). The rules live in
  `SimpleFit.Billing` and `SimpleFit.Entitlements`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.{Billing, Entitlements}
  alias SimpleFitWeb.{ApiSpec, Schemas}
  alias SimpleFitWeb.Schemas.CommerceFields

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.BillingJSON

  tags ["SimpleFit plans"]

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

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never
    revealed); for a subscription, also an unknown id or another gym's.
  * `forbidden` - only the gym's owner acts on its SimpleFit subscription (`manage_billing`).
  """

  @subscription {"The subscription", "application/json", Schemas.GymSaasSubscriptionResponse}

  operation :plans,
    operation_id: "listSaasPlans",
    summary: "SimpleFit plans",
    description: """
    The plan versions SimpleFit has published under an approval, by plan key, with their immutable prices and
    included features. Empty until one is published: drafts (including the provisional catalog) are never
    shown. Any signed-in user.
    """,
    security: @security,
    responses: [
      ok: {"The plans", "application/json", Schemas.SaasPlanList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def plans(conn, _params) do
    conn |> no_store() |> render(:plans, plans: Billing.published_plans())
  end

  operation :index,
    operation_id: "listGymSaasSubscriptions",
    summary: "A gym's SimpleFit subscriptions",
    description: """
    The gym's SimpleFit subscriptions (intents included), newest first.

    #{@access}
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: {"The subscriptions", "application/json", Schemas.GymSaasSubscriptionList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, %{"gym_id" => gym_id}) do
    with {:ok, list} <- Billing.list_gym_subscriptions(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:subscriptions, subscriptions: list)
    end
  end

  operation :create,
    operation_id: "requestGymSaasSubscription",
    summary: "Ask for a SimpleFit plan",
    description: """
    Records the gym's intent to subscribe to a published plan version at one of its `fixed` prices: a
    `pending_activation` subscription that grants nothing and charges nothing. Only verified evidence from a
    payment provider activates it, and none is integrated yet. The same `client_request_id` again returns that
    intent (`200`).

    #{@access}
    * `conflict` - `details.saas_subscription: "current_exists"` (the gym has a pending, active or scheduled
      subscription); `details.saas_plan_version` (not published: `superseded`, `retired`, ...);
      `details.saas_price_version: "not_found"` or `"quote_required"`; `details.client_request_id: "reused"`;
      a draft gym (`details.setup_status`).
    * `validation_error` - a missing, invalid or unknown field (a `status`, receipt or payment field included).
    * `rate_limited` - 30 changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"The plan and price", "application/json", Schemas.GymSaasSubscriptionRequest,
       required: true},
    responses: [
      created: @subscription,
      ok:
        {"The intent this `client_request_id` already recorded", "application/json",
         Schemas.GymSaasSubscriptionResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create(conn, %{"gym_id" => gym_id}) do
    with {:ok, {subscription, outcome}} <-
           Billing.request_gym_subscription(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:subscription, subscription: subscription)
    end
  end

  operation :cancel,
    operation_id: "cancelGymSaasSubscription",
    summary: "Cancel the gym's SimpleFit subscription",
    description: """
    #{CommerceFields.cancel_rules()}
    #{@access}
    * `conflict` - `details.saas_subscription: "expired"`; a draft gym (`details.setup_status`).
    * `validation_error` - `mode` missing or invalid, or an unknown field.
    * `rate_limited` - 30 changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [
      @gym_id,
      %Parameter{
        name: :subscription_id,
        in: :path,
        required: true,
        description: "A subscription of this gym.",
        schema: %Schema{type: :string, format: :uuid}
      }
    ],
    request_body:
      {"The mode", "application/json", Schemas.SubscriptionCancelRequest, required: true},
    responses: [
      ok: @subscription,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel(conn, %{"gym_id" => gym_id, "subscription_id" => id}) do
    with {:ok, subscription} <-
           Billing.cancel_gym_subscription(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:subscription, subscription: subscription)
    end
  end

  operation :entitlements,
    operation_id: "getGymEntitlements",
    summary: "A gym's SimpleFit entitlements",
    description: """
    Every registered feature with the backend's decision for this gym. A feature is `entitled` only through a
    subscription that is active (or scheduled to cancel) with verified provider evidence, inside its paid period,
    whose plan version includes it; otherwise `denied` with a `reason`. Informational: no endpoint gates on a
    feature yet (`enforced: false`). Any active staff member (`view_workspace`).

    * `not_found` - no such gym, or the viewer holds no active staff membership there.
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: {"The entitlements", "application/json", Schemas.GymEntitlements},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def entitlements(conn, %{"gym_id" => gym_id}) do
    with {:ok, projection} <- Entitlements.gym_projection(conn.assigns.current_user, gym_id) do
      conn |> no_store() |> render(:entitlements, projection: projection)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
