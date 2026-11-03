defmodule SimpleFitWeb.MyGymProductController do
  @moduledoc """
  A member's side of their gym's products (SF-101; ADR 0026): the products
  of the gym of one of their own active memberships, asking for one (an
  intent that grants nothing), their product subscriptions and cancelling
  one. Account-scoped; no Fighter profile is needed. Nothing is charged.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.GymCommerceJSON

  tags ["Gym member products"]

  @security [%{"bearerAuth" => []}]

  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{
                   "retry-after" => %Header{
                     description: "Seconds until another request is accepted.",
                     schema: %Schema{type: :integer}
                   }
                 }}

  @gym_member_id %Parameter{
    name: :gym_member_id,
    in: :path,
    required: true,
    description: "One of the viewer's own memberships (it must be active).",
    schema: %Schema{type: :string, format: :uuid}
  }

  @member_access """
  * `not_found` - not one of the viewer's own memberships.
  * `conflict` - `details.gym_member` is the membership's status when it is not `active`.
  """

  @subscription {"The subscription", "application/json",
                 Schemas.GymMemberProductSubscriptionResponse}

  operation :offers,
    operation_id: "listMyGymProducts",
    summary: "The products of my gym",
    description: """
    The active products of the gym of one of the viewer's own active memberships, with their published
    version and current prices.

    #{@member_access}
    """,
    security: @security,
    parameters: [@gym_member_id],
    responses: [
      ok: {"The products", "application/json", Schemas.GymMemberOfferList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def offers(conn, %{"gym_member_id" => member_id}) do
    with {:ok, products} <- Gyms.list_my_gym_products(conn.assigns.current_user, member_id) do
      conn |> no_store() |> render(:offers, products: products)
    end
  end

  operation :create,
    operation_id: "requestMyGymProduct",
    summary: "Ask for a product of my gym",
    description: """
    Records the viewer's intent to buy a product of their gym at its published version and current price: a
    `pending_activation` subscription that grants no admission and charges nothing (no payment provider is
    integrated). Booking classes is unchanged. The same `client_request_id` again returns that intent (`200`).

    #{@member_access}
    * `not_found` - also an unknown product version, or another gym's.
    * `conflict` - also `details.member_product: "retired"`; `details.member_product_version` (not the
      published version: `draft`, `superseded`, ...); `details.member_price_version: "superseded"` (not the current price in its
      currency) or `"not_found"`; `details.client_request_id: "reused"`.
    * `validation_error` - a missing, invalid or unknown field (a `status`, receipt or payment field included).
    * `rate_limited` - 30 changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_member_id],
    request_body:
      {"The product and price", "application/json", Schemas.GymMemberProductSubscriptionRequest,
       required: true},
    responses: [
      created: @subscription,
      ok:
        {"The intent this `client_request_id` already recorded", "application/json",
         Schemas.GymMemberProductSubscriptionResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create(conn, %{"gym_member_id" => member_id}) do
    with {:ok, {view, outcome}} <-
           Gyms.request_member_product_subscription(
             conn.assigns.current_user,
             conn.assigns.current_session,
             member_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:subscription, subscription: view)
    end
  end

  operation :index,
    operation_id: "listMyProductSubscriptions",
    summary: "My product subscriptions",
    description: """
    The viewer's product subscriptions at every gym, newest first.

    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
      %Parameter{
        name: :status,
        in: :query,
        required: false,
        description: "Only subscriptions in this status (default: all).",
        schema: %Schema{
          type: :string,
          enum: ["pending_activation", "active", "cancellation_scheduled", "cancelled", "expired"]
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
        description: "`next_cursor` of the previous page (same filters).",
        schema: %Schema{type: :string}
      }
    ],
    responses: [
      ok: {"The subscriptions", "application/json", Schemas.GymMemberProductSubscriptionList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, params) do
    with {:ok, page} <- Gyms.list_my_product_subscriptions(conn.assigns.current_user, params) do
      conn |> no_store() |> render(:subscriptions, page: page)
    end
  end

  operation :cancel,
    operation_id: "cancelMyProductSubscription",
    summary: "Cancel one of my product subscriptions",
    description: """
    Cancels one of the viewer's own product subscriptions at once (an intent or an active one). Repeating it
    returns it unchanged. No refund exists.

    * `not_found` - not one of the viewer's own subscriptions.
    * `conflict` - `details.member_product_subscription: "expired"`.
    """,
    security: @security,
    parameters: [
      %Parameter{
        name: :subscription_id,
        in: :path,
        required: true,
        description: "One of the viewer's own product subscriptions.",
        schema: %Schema{type: :string, format: :uuid}
      }
    ],
    responses: [
      ok: @subscription,
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel(conn, %{"subscription_id" => id}) do
    with {:ok, view} <-
           Gyms.cancel_my_product_subscription(
             conn.assigns.current_user,
             conn.assigns.current_session,
             id
           ) do
      conn |> no_store() |> render(:subscription, subscription: view)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
