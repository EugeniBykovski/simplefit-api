defmodule SimpleFit.BillingHelpers do
  @moduledoc """
  Fixtures for SF-101 commerce tests: SimpleFit plans (through the operator
  catalog), gym SaaS subscriptions, gym member products and member product
  subscriptions, all through the public contexts. Activation goes through
  `SimpleFit.BillingTestProvider`, the test-only trusted provider.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{Billing, BillingTestProvider, GymHelpers, Gyms, Repo}

  alias SimpleFit.Billing.{
    ActivationEvidence,
    AuditEvent,
    Catalog,
    Plan,
    PlanEntitlement,
    PlanVersion,
    PriceVersion
  }

  @operator "ops@test"

  @doc "The operator name used in catalog fixtures."
  def operator, do: @operator

  @doc "A unique plan key."
  def plan_key(prefix \\ "plan"),
    do: "#{prefix}_#{System.unique_integer([:positive])}"

  @doc "Draft attributes with PLN month/year prices (decimal strings)."
  def plan_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Starter",
        "description" => "Test plan",
        "price_source" => "product_decision",
        "prices" => [
          %{"interval" => "month", "currency" => "PLN", "amount" => "149"},
          %{"interval" => "year", "currency" => "PLN", "amount" => "1490"}
        ],
        "entitlements" => [%{"feature_key" => "gym.member_management"}]
      },
      overrides
    )
  end

  @doc "A draft plan version of a new plan (asserting success)."
  def draft_plan!(overrides \\ %{}, key \\ plan_key()) do
    {:ok, version} = Catalog.draft(key, plan_attrs(overrides), @operator)
    version
  end

  @doc "A published plan version of a new plan (asserting success)."
  def published_plan!(overrides \\ %{}, key \\ plan_key()) do
    version = draft_plan!(overrides, key)
    {:ok, published} = Catalog.publish(version.id, "SF-101-TEST", @operator)
    published
  end

  @doc "The plan version's price for `interval` (and PLN)."
  def price(version, interval \\ :month),
    do: Enum.find(version.prices, &(&1.interval == interval and &1.currency == "PLN"))

  @doc "Requests a SaaS subscription as `user` (the raw result)."
  def request_saas(%User{} = user, gym_id, version, price, key \\ Ecto.UUID.generate()) do
    Billing.request_gym_subscription(user, GymHelpers.live_session!(user), gym_id, %{
      "plan_version_id" => version.id,
      "price_version_id" => price.id,
      "client_request_id" => key
    })
  end

  @doc "A pending SaaS subscription (asserting success)."
  def pending_saas!(%User{} = owner, gym_id, version) do
    {:ok, {subscription, :created}} = request_saas(owner, gym_id, version, price(version))
    subscription
  end

  @doc "Evidence for the test provider covering `[from, to)`."
  def evidence(from, to, reference \\ "ref_#{Ecto.UUID.generate()}"),
    do: %{reference: reference, period_start: from, period_end: to}

  @doc "Activates a SaaS subscription through the test provider (the raw result)."
  def activate_saas(subscription_id, from, to, now \\ nil, reference \\ nil) do
    payload = evidence(from, to, reference || "ref_#{Ecto.UUID.generate()}")

    Billing.Subscriptions.activate(
      subscription_id,
      BillingTestProvider,
      payload,
      now || from
    )
  end

  @doc "An active SaaS subscription (asserting success)."
  def active_saas!(%User{} = owner, gym_id, version, from, to) do
    subscription = pending_saas!(owner, gym_id, version)
    {:ok, active} = activate_saas(subscription.id, from, to)
    active
  end

  @doc "Creates a member product as `admin` (the raw result)."
  def create_product(%User{} = admin, gym_id, attrs) do
    Gyms.create_member_product(
      admin,
      GymHelpers.live_session!(admin),
      gym_id,
      Map.merge(
        %{
          "client_request_id" => Ecto.UUID.generate(),
          "key" => "pack_#{System.unique_integer([:positive])}",
          "product_type" => "class_pack",
          "name" => "4-Class Pack",
          "class_credits" => 4,
          "validity_days" => 30,
          "price" => %{"currency" => "PLN", "amount" => "169.00"}
        },
        attrs
      )
    )
  end

  @doc "A member product with its draft version (asserting success)."
  def product!(%User{} = admin, gym_id, attrs \\ %{}) do
    {:ok, {view, :created}} = create_product(admin, gym_id, attrs)
    view
  end

  @doc "A member product whose first version is published (asserting success)."
  def published_product!(%User{} = admin, gym_id, attrs \\ %{}) do
    product = product!(admin, gym_id, attrs)
    publish!(admin, gym_id, product)
  end

  @doc "Publishes the product's draft (asserting success)."
  def publish!(%User{} = admin, gym_id, product) do
    {:ok, view} =
      Gyms.publish_member_product_version(
        admin,
        GymHelpers.live_session!(admin),
        gym_id,
        product.product_id,
        product.draft.version_id
      )

    view
  end

  @doc "Asks for the product's published version at its current PLN price as `user` (raw result)."
  def request_product(%User{} = user, member_id, product, key \\ Ecto.UUID.generate()) do
    [price] = Enum.filter(product.published.current_prices, &(&1.currency == "PLN"))

    Gyms.request_member_product_subscription(user, GymHelpers.live_session!(user), member_id, %{
      "product_version_id" => product.published.version_id,
      "price_version_id" => price.price_version_id,
      "client_request_id" => key
    })
  end

  @doc """
  Deletes catalog rows committed outside the sandbox (real-commit tests):
  plans by key with their versions, prices, entitlements and audit events,
  and activation evidence by reference, through the maintenance switch.
  Gym-owned rows go with `SimpleFit.GymHelpers.purge_gyms!/1`, first.
  """
  def purge_billing!(plan_keys, references \\ []) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL simple_fit.allow_gym_member_purge = 'on'")

        plan_ids = Repo.all(from(p in Plan, where: p.key in ^plan_keys, select: p.id))

        version_ids =
          Repo.all(from(v in PlanVersion, where: v.plan_id in ^plan_ids, select: v.id))

        Repo.delete_all(from(e in AuditEvent, where: e.plan_id in ^plan_ids))
        Repo.delete_all(from(p in PriceVersion, where: p.plan_version_id in ^version_ids))
        Repo.delete_all(from(e in PlanEntitlement, where: e.plan_version_id in ^version_ids))
        Repo.delete_all(from(v in PlanVersion, where: v.id in ^version_ids))
        Repo.delete_all(from(p in Plan, where: p.id in ^plan_ids))
        Repo.delete_all(from(e in ActivationEvidence, where: e.provider_reference in ^references))
      end)

    :ok
  end
end
