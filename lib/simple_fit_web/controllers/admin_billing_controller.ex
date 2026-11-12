defmodule SimpleFitWeb.AdminBillingController do
  @moduledoc """
  Operator billing oversight (SF-127): read-only projections of SimpleFit's SaaS
  billing (SF-101) and its Stripe records (SF-102), one Stripe mode at a time. No
  refund, cancellation, price, entitlement, retry, replay or reconcile action exists
  here, and no route forwards anything to Stripe. The rules live in
  `SimpleFit.Operators` and `SimpleFit.Billing.Oversight`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.AdminBillingJSON

  tags ["Platform operators"]

  @security [%{"bearerAuth" => []}]

  @access """
  * `not_found` - not a usable operator (indistinguishable from an unknown route), or no such record.
  * `enrollment_required`, `forbidden` (permission), `step_up_required` (key check).
  """

  @base [
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  @invalid [unprocessable_entity: ApiSpec.error_response("validation_error")]

  @mode [
    in: :query,
    schema: %Schema{
      type: :string,
      enum: ["test", "live"],
      description: "The Stripe mode to read; the deployment's configured mode by default."
    }
  ]

  @page [
    limit: [in: :query, schema: %Schema{type: :integer, minimum: 1, maximum: 50, default: 25}],
    cursor: [in: :query, schema: %Schema{type: :string, maxLength: 1024}]
  ]

  operation :overview,
    operation_id: "getAdminBillingOverview",
    summary: "The billing overview of one Stripe mode",
    description:
      "Needs `billing.read` and a key check. Counts by status and the gross amount paid of invoices paid in " <>
        "the last 30 days per currency, all of one mode; no MRR, ARR or revenue figure exists. Not recorded " <>
        "per load (counts only).\n\n" <> @access <> "* `validation_error` - an unknown mode.",
    security: @security,
    parameters: [mode: @mode],
    responses:
      [ok: {"Overview", "application/json", Schemas.AdminBillingOverviewResponse}] ++
        @invalid ++ @base

  def overview(conn, params) do
    with {:ok, overview} <-
           Operators.billing_overview(
             user(conn),
             session(conn),
             Map.take(params, ["mode"]),
             ctx()
           ) do
      conn |> no_store() |> render(:overview, overview: overview)
    end
  end

  operation :plans,
    operation_id: "listAdminBillingPlans",
    summary: "The SaaS plan catalog",
    description:
      "Needs `billing.read` and a key check. Every plan with every version as recorded, its prices and the " <>
        "modes each price is mapped to Stripe in. Read only.\n\n" <> @access,
    security: @security,
    responses: [ok: {"Plans", "application/json", Schemas.AdminBillingPlanListResponse}] ++ @base

  def plans(conn, _params) do
    with {:ok, plans} <- Operators.billing_plans(user(conn), session(conn), ctx()) do
      conn |> no_store() |> render(:plans, plans: plans)
    end
  end

  operation :plan,
    operation_id: "getAdminBillingPlan",
    summary: "One plan's version history",
    description:
      "Needs `billing.read` and a key check. Every version with its prices and entitlements; nothing is " <>
        "recomputed from a newer version.\n\n" <> @access,
    security: @security,
    parameters: [
      plan_key: [
        in: :path,
        schema: %Schema{type: :string, pattern: "^[a-z][a-z0-9_]{1,39}$"},
        required: true
      ]
    ],
    responses: [ok: {"The plan", "application/json", Schemas.AdminBillingPlanResponse}] ++ @base

  def plan(conn, %{"plan_key" => key}) do
    with {:ok, plan} <- Operators.billing_plan(user(conn), session(conn), key, ctx()) do
      conn |> no_store() |> render(:plan, plan: plan)
    end
  end

  operation :subscriptions,
    operation_id: "listAdminBillingSubscriptions",
    summary: "One page of gym SaaS subscriptions",
    description:
      "Needs `billing.read` and a key check. One environment (`test`, `live`, or `none`: no provider record), " <>
        "newest request first. Every query is recorded (`billing.subscriptions_listed`).\n\n" <>
        @access <> "* `validation_error` - an unknown filter value or an invalid cursor.",
    security: @security,
    parameters:
      [
        mode: [
          in: :query,
          schema: %Schema{
            type: :string,
            enum: ["test", "live", "none"],
            description: "The environment; the deployment's configured mode by default."
          }
        ],
        status: [
          in: :query,
          schema: %Schema{
            type: :string,
            enum: ~w(pending_activation active cancellation_scheduled cancelled expired)
          }
        ],
        plan_key: [in: :query, schema: %Schema{type: :string, pattern: "^[a-z][a-z0-9_]{1,39}$"}],
        plan_version_id: [in: :query, schema: %Schema{type: :string, format: :uuid}],
        gym_id: [in: :query, schema: %Schema{type: :string, format: :uuid}]
      ] ++ @page,
    responses:
      [ok: {"A page", "application/json", Schemas.AdminBillingSubscriptionListResponse}] ++
        @invalid ++ @base

  def subscriptions(conn, params) do
    with {:ok, page} <-
           Operators.list_billing_subscriptions(
             user(conn),
             session(conn),
             Map.take(params, ~w(mode status plan_key plan_version_id gym_id limit cursor)),
             ctx()
           ) do
      conn |> no_store() |> render(:subscriptions, page: page)
    end
  end

  operation :subscription,
    operation_id: "getAdminBillingSubscription",
    summary: "One gym SaaS subscription",
    description:
      "Needs `billing.read` and a key check. Its periods, newest recorded invoices with refunds and disputes, " <>
        "and checkout states; recorded (`billing.subscription_viewed`). No action is offered.\n\n" <>
        @access,
    security: @security,
    parameters: [
      subscription_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses:
      [ok: {"The subscription", "application/json", Schemas.AdminBillingSubscriptionResponse}] ++
        @base

  def subscription(conn, %{"subscription_id" => id}) do
    with {:ok, subscription} <-
           Operators.get_billing_subscription(user(conn), session(conn), id, ctx()) do
      conn |> no_store() |> render(:subscription, subscription: subscription)
    end
  end

  operation :invoices,
    operation_id: "listAdminBillingInvoices",
    summary: "One page of recorded Stripe invoices",
    description:
      "Needs `billing.read` and a key check. One mode, newest first; `issue` filters payment problems. " <>
        "Every query is recorded (`billing.invoices_listed`).\n\n" <>
        @access <> "* `validation_error` - an unknown filter value or an invalid cursor.",
    security: @security,
    parameters:
      [
        mode: @mode,
        status: [
          in: :query,
          schema: %Schema{type: :string, enum: ~w(draft open paid uncollectible void)}
        ],
        payment_status: [
          in: :query,
          schema: %Schema{
            type: :string,
            enum: ~w(requires_action requires_payment_method processing succeeded canceled)
          }
        ],
        issue: [
          in: :query,
          schema: %Schema{
            type: :string,
            enum: ~w(any payment_failed action_required uncollectible)
          }
        ],
        currency: [in: :query, schema: %Schema{type: :string, pattern: "^[A-Z]{3}$"}],
        gym_id: [in: :query, schema: %Schema{type: :string, format: :uuid}]
      ] ++ @page,
    responses:
      [ok: {"A page", "application/json", Schemas.AdminBillingInvoiceListResponse}] ++
        @invalid ++ @base

  def invoices(conn, params) do
    with {:ok, page} <-
           Operators.list_billing_invoices(
             user(conn),
             session(conn),
             Map.take(params, ~w(mode status payment_status issue currency gym_id limit cursor)),
             ctx()
           ) do
      conn |> no_store() |> render(:invoices, page: page)
    end
  end

  operation :reconciliation,
    operation_id: "getAdminBillingReconciliation",
    summary: "Reconciliation of one Stripe mode",
    description:
      "Needs `billing.reconciliation.read` and a key check. Links by state, the webhook inbox and one page " <>
        "of discrepancies; recorded (`billing.reconciliation_read`). No reconcile, sync or replay action " <>
        "exists.\n\n" <> @access <> "* `validation_error` - an unknown mode or an invalid cursor.",
    security: @security,
    parameters: [mode: @mode] ++ @page,
    responses:
      [ok: {"Reconciliation", "application/json", Schemas.AdminBillingReconciliationResponse}] ++
        @invalid ++ @base

  def reconciliation(conn, params) do
    with {:ok, reconciliation} <-
           Operators.billing_reconciliation(
             user(conn),
             session(conn),
             Map.take(params, ~w(mode limit cursor)),
             ctx()
           ) do
      conn |> no_store() |> render(:reconciliation, reconciliation: reconciliation)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
  defp user(conn), do: conn.assigns.current_user
  defp session(conn), do: conn.assigns.current_session
  defp ctx, do: %{request_id: Logger.metadata()[:request_id]}
end
