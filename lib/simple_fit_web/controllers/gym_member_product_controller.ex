defmodule SimpleFitWeb.GymMemberProductController do
  @moduledoc """
  A gym's own member products as its staff manage them, and its members'
  product subscriptions (SF-101; ADR 0026). Every action acts for the
  session's own user on the gym named in the path; the rules live in
  `SimpleFit.Gyms`. Nothing here charges, activates or debits.
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

  @gym_id %Parameter{
    name: :gym_id,
    in: :path,
    required: true,
    description: "The gym.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @product_id %Parameter{
    name: :product_id,
    in: :path,
    required: true,
    description: "A product of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @version_id %Parameter{
    name: :version_id,
    in: :path,
    required: true,
    description: "A version of this product.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never
    revealed); for a product or version, also an unknown id or another gym's.
  * `forbidden` - the viewer's role may not do this.
  """

  @write_access """
  #{@access}
  * `conflict` - `details.member_product: "retired"`; a draft gym (`details.setup_status`).
  * `rate_limited` - 60 changes per 10 minutes per user.
  """

  @product {"The product", "application/json", Schemas.GymMemberProductResponse}

  @write_errors [
    unauthorized: ApiSpec.error_response("unauthorized"),
    forbidden: ApiSpec.error_response("forbidden"),
    not_found: ApiSpec.error_response("not_found"),
    conflict: ApiSpec.error_response("conflict"),
    unprocessable_entity: ApiSpec.error_response("validation_error"),
    too_many_requests: @rate_limited,
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  operation :index,
    operation_id: "listGymMemberProducts",
    summary: "A gym's member products",
    description: """
    Every product of the gym (active and retired), oldest first, with its versions and prices. Owner, managers
    and front desk (`view_member_products`).

    #{@access}
    """,
    security: @security,
    parameters: [@gym_id],
    responses: [
      ok: {"The products", "application/json", Schemas.GymMemberProductList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, products} <- Gyms.list_member_products(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:products, products: products)
    end
  end

  operation :show,
    operation_id: "getGymMemberProduct",
    summary: "A gym member product",
    description: """
    One product with every version and price. Owner, managers and front desk (`view_member_products`).

    #{@access}
    """,
    security: @security,
    parameters: [@gym_id, @product_id],
    responses: [
      ok: @product,
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def show(conn, %{"gym_id" => gym_id, "product_id" => id}) do
    with {:ok, product} <- Gyms.get_member_product(conn.assigns.current_user, gym_id, id) do
      conn |> no_store() |> render(:product, product: product)
    end
  end

  operation :create,
    operation_id: "createGymMemberProduct",
    summary: "Create a member product",
    description: """
    Creates a product with its first version as a draft and that version's first price. Nothing is offered
    until the version is published. The same `client_request_id` again returns that product (`200`). Owner and
    managers (`manage_member_products`).

    #{@access}
    * `conflict` - `details.member_product: "key_taken"` (another product of this gym has the key);
      `details.client_request_id: "reused"`; a draft gym (`details.setup_status`).
    * `validation_error` - a missing, invalid or unknown field; credits or validity not allowed for the type; an
      amount that is not a decimal string, negative or too precise for the currency; an unsupported currency.
    * `rate_limited` - 60 changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"The product", "application/json", Schemas.GymMemberProductCreateRequest, required: true},
    responses:
      [
        created: @product,
        ok:
          {"The product this `client_request_id` already created", "application/json",
           Schemas.GymMemberProductResponse}
      ] ++ @write_errors

  def create(conn, %{"gym_id" => gym_id}) do
    with {:ok, {product, outcome}} <-
           Gyms.create_member_product(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:product, product: product)
    end
  end

  operation :create_version,
    operation_id: "createGymMemberProductVersion",
    summary: "Draft a new product version",
    description: """
    Adds a draft version (new content and its first price) to an active product. One draft at a time; the
    published version and its subscriptions stay unchanged. Owner and managers (`manage_member_products`).

    #{@write_access}
    * `conflict` - also `details.member_product: "draft_exists"`.
    * `validation_error` - as for creating a product.
    """,
    security: @security,
    parameters: [@gym_id, @product_id],
    request_body:
      {"The version", "application/json", Schemas.GymMemberProductVersionRequest, required: true},
    responses: [created: @product] ++ @write_errors

  def create_version(conn, %{"gym_id" => gym_id, "product_id" => id}) do
    with {:ok, product} <-
           Gyms.create_member_product_version(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> put_status(:created) |> render(:product, product: product)
    end
  end

  operation :publish_version,
    operation_id: "publishGymMemberProductVersion",
    summary: "Publish a product version",
    description: """
    Publishes a draft version: members can ask for it at its current prices, and the previously published
    version becomes `superseded` (its subscriptions keep it). Owner and managers (`manage_member_products`).

    #{@write_access}
    * `conflict` - also `details.member_product_version` (not a draft: `published`, `superseded`, ...; or
      `"no_prices"`).
    """,
    security: @security,
    parameters: [@gym_id, @product_id, @version_id],
    responses: [ok: @product] ++ @write_errors

  def publish_version(conn, %{"gym_id" => gym_id, "product_id" => id, "version_id" => version}) do
    with {:ok, product} <-
           Gyms.publish_member_product_version(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             version
           ) do
      conn |> no_store() |> render(:product, product: product)
    end
  end

  operation :add_price,
    operation_id: "addGymMemberProductPrice",
    summary: "Add a price to a product version",
    description: """
    Appends a price to a draft or published version. It becomes the current price in its currency for new
    subscriptions; existing subscriptions keep theirs. Prices are never edited. The same `client_request_id`
    again returns the product (`200`). Owner and managers (`manage_member_products`).

    #{@write_access}
    * `conflict` - also `details.member_product_version` (`superseded`, `retired` or `archived`);
      `details.client_request_id: "reused"`.
    * `validation_error` - an amount that is not a decimal string, negative or too precise; an unsupported
      currency; an unknown field.
    """,
    security: @security,
    parameters: [@gym_id, @product_id, @version_id],
    request_body:
      {"The price", "application/json", Schemas.GymMemberPriceRequest, required: true},
    responses:
      [
        created: @product,
        ok:
          {"The product, for a price this `client_request_id` already added", "application/json",
           Schemas.GymMemberProductResponse}
      ] ++ @write_errors

  def add_price(conn, %{"gym_id" => gym_id, "product_id" => id, "version_id" => version}) do
    with {:ok, {product, outcome}} <-
           Gyms.add_member_product_price(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             version,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:product, product: product)
    end
  end

  operation :retire,
    operation_id: "retireGymMemberProduct",
    summary: "Retire a member product",
    description: """
    Stops new subscriptions to the product: its published version retires and its draft is archived. Existing
    subscriptions are untouched. Repeating it returns the product unchanged. Owner and managers
    (`manage_member_products`).

    #{@access}
    * `conflict` - a draft gym (`details.setup_status`).
    * `rate_limited` - 60 changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @product_id],
    responses: [ok: @product] ++ @write_errors

  def retire(conn, %{"gym_id" => gym_id, "product_id" => id}) do
    with {:ok, product} <-
           Gyms.retire_member_product(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id
           ) do
      conn |> no_store() |> render(:product, product: product)
    end
  end

  operation :subscriptions,
    operation_id: "listGymMemberProductSubscriptions",
    summary: "A gym's member product subscriptions",
    description: """
    The product subscriptions of the gym's members (intents included), newest first, with a short member name.
    Never an email or payment detail. Owner, managers and front desk (`view_member_product_subscriptions`).

    #{@access}
    * `validation_error` - `status`, `limit` or `cursor` is invalid.
    """,
    security: @security,
    parameters: [
      @gym_id,
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
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def subscriptions(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <-
           Gyms.list_member_product_subscriptions(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:subscriptions, page: page)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
