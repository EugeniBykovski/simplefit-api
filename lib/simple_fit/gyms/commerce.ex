defmodule SimpleFit.Gyms.Commerce do
  @moduledoc """
  A gym's own member products and its members' product subscriptions
  (SF-101; SF-82 05 concept B). Internal to `SimpleFit.Gyms`. Independent of
  SimpleFit's SaaS plans (`SimpleFit.Billing`): no table, state or
  entitlement is shared.

  ## Catalog (staff)

  * Owner and managers change the catalog (`manage_member_products`); the
    front desk reads it (`view_member_products`); coaches hold no commercial
    permission. Every product belongs to one gym; another gym's id is `404`.
  * A product has a key, a type and versions. A version holds the name,
    description, class admissions (`class_credits`) and validity
    (`validity_days`): `single_visit` grants 1 admission (validity
    optional), `class_pack` 2-500 admissions within a validity,
    `unlimited_period` unlimited admissions within a validity. Recurring
    renewals do not exist (no renewal source).
  * One draft at a time; publishing it supersedes the published version,
    which stays immutable with its subscriptions. Retiring the product stops
    new subscriptions; existing ones are untouched.
  * Prices are append-only per version and currency (integer minor units,
    zero allowed, never a float): a new price becomes current for new
    subscriptions, earlier subscriptions keep theirs.

  ## Member subscriptions

  * An active member (no Fighter profile needed) asks for a published
    product at its current price: a `pending_activation` intent that grants
    nothing. A staff membership grants no product, and gym membership is
    never a paid subscription. Activation needs a trusted provider's
    evidence (`SimpleFit.Billing.Activation`; none outside tests), so no
    class admission is ever issued or debited here, and SF-99 bookings stay
    as they are (no class requires a product).
  * A `client_request_id` names one intent for ever; cancelling is
    idempotent; nothing is refunded, invoiced or charged.

  ## Locks

  Staff writes take `SimpleFit.Gyms.Guarded.write/6` (session, gym and
  staff membership locked), then the product row (`FOR UPDATE`), so
  concurrent publications or prices of one product serialize. A member's
  intent holds the session, the gym (`FOR SHARE`) and the member row.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.{Accounts, Clock, Money, RateLimit, Repo}
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Billing.Activation

  alias SimpleFit.Gyms.{
    Access,
    Audit,
    Guarded,
    Gym,
    Member,
    MemberPriceVersion,
    MemberProduct,
    MemberProductSubscription,
    MemberProductVersion,
    Members,
    MemberSecrets,
    Paging
  }

  @unlogged [log: false]
  @staff_limit {"gym_commerce_admin_user", 60, 600}
  @member_limit {"gym_commerce_member_user", 30, 600}

  @product_fields ~w(client_request_id key product_type name description class_credits validity_days price)
  @version_fields ~w(client_request_id name description class_credits validity_days price)
  @price_fields ~w(client_request_id currency amount)
  @request_fields ~w(product_version_id price_version_id client_request_id)

  @type error ::
          :not_found
          | :forbidden
          | :session_revoked
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | Changeset.t()

  ## Catalog reads

  @doc "The gym's products with their published version and current prices (`view_member_products`)."
  @spec list_products(User.t(), term(), map()) ::
          {:ok, [map()]} | {:error, :not_found | :forbidden}
  def list_products(%User{} = user, gym_id, _params) do
    with {:ok, access} <- Access.authorize(user, gym_id, :view_member_products) do
      products =
        Repo.all(
          from(p in MemberProduct,
            where: p.gym_id == ^access.gym.id,
            order_by: [asc: p.inserted_at, asc: p.id],
            preload: [versions: ^versions_order()]
          ),
          @unlogged
        )

      {:ok, Enum.map(products, &product_view/1)}
    end
  end

  @doc "One product with every version and price history (`view_member_products`)."
  @spec get_product(User.t(), term(), term()) :: {:ok, map()} | {:error, :not_found | :forbidden}
  def get_product(%User{} = user, gym_id, product_id) do
    with {:ok, access} <- Access.authorize(user, gym_id, :view_member_products),
         {:ok, product} <- fetch_product(access.gym.id, product_id) do
      {:ok, product_view(product)}
    end
  end

  ## Catalog writes

  @doc "Creates a product, its first (draft) version and that version's first price."
  @spec create_product(User.t(), Session.t(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, error()}
  def create_product(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    with {:ok, fields} <- product_fields(attrs) do
      staff_write(user, session, gym_id, &create_product_in(&1, user, fields, &2))
    end
  end

  @doc "Adds a draft version to an active product (one draft at a time)."
  @spec create_version(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, error()}
  def create_version(%User{} = user, %Session{} = session, gym_id, product_id, attrs)
      when is_map(attrs) do
    staff_write(user, session, gym_id, fn access, now ->
      with {:ok, product} <- lock_product(access.gym.id, product_id),
           {:ok, fields} <- version_fields(attrs, product.product_type),
           :ok <- active_product(product),
           :ok <- no_draft(product) do
        version = insert_version!(product, fields, next_version(product))
        insert_price!(version, fields.price, fields.client_request_id, 1, user)
        audit!(access.gym.id, user.id, :member_product_version_created, now, version_ids(version))
        {:ok, product_view(fetch_product!(product.id))}
      end
    end)
  end

  @doc "Publishes a draft version; the published one becomes superseded."
  @spec publish_version(User.t(), Session.t(), term(), term(), term()) ::
          {:ok, map()} | {:error, error()}
  def publish_version(%User{} = user, %Session{} = session, gym_id, product_id, version_id) do
    staff_write(user, session, gym_id, fn access, now ->
      with {:ok, product} <- lock_product(access.gym.id, product_id),
           :ok <- active_product(product),
           {:ok, version} <- lock_version(product, version_id),
           :ok <- version_status(version, [:draft]),
           :ok <- priced(version) do
        Repo.update_all(
          from(v in MemberProductVersion,
            where: v.product_id == ^product.id and v.status == :published
          ),
          [set: [status: :superseded, superseded_at: now, updated_at: now]],
          @unlogged
        )

        version
        |> Changeset.change(
          status: :published,
          published_at: now,
          published_by_user_id: user.id,
          revision: version.revision + 1
        )
        |> Repo.update!(@unlogged)

        audit!(
          access.gym.id,
          user.id,
          :member_product_version_published,
          now,
          version_ids(version)
        )

        {:ok, product_view(fetch_product!(product.id))}
      end
    end)
  end

  @doc """
  Appends a price to a draft or published version (`client_request_id`,
  `currency`, `amount` as a decimal string). It becomes the current price in
  its currency; existing subscriptions keep theirs.
  """
  @spec add_price(User.t(), Session.t(), term(), term(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, error()}
  def add_price(%User{} = user, %Session{} = session, gym_id, product_id, version_id, attrs)
      when is_map(attrs) do
    with {:ok, fields} <- price_fields(attrs) do
      staff_write(
        user,
        session,
        gym_id,
        &add_price_in(&1, user, product_id, version_id, fields, &2)
      )
    end
  end

  @doc "Retires a product: no new subscription; its published version retires, its draft is archived."
  @spec retire_product(User.t(), Session.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def retire_product(%User{} = user, %Session{} = session, gym_id, product_id) do
    staff_write(user, session, gym_id, fn access, now ->
      with {:ok, product} <- lock_product(access.gym.id, product_id) do
        retire_in(access, user, product, now)
      end
    end)
  end

  defp retire_in(_access, _user, %MemberProduct{status: :retired} = product, _now),
    do: {:ok, product_view(fetch_product!(product.id))}

  defp retire_in(access, user, product, now) do
    Repo.update_all(
      from(v in MemberProductVersion,
        where: v.product_id == ^product.id and v.status in [:published, :superseded]
      ),
      [set: [status: :retired, retired_at: now, updated_at: now]],
      @unlogged
    )

    Repo.update_all(
      from(v in MemberProductVersion, where: v.product_id == ^product.id and v.status == :draft),
      [set: [status: :archived, archived_at: now, updated_at: now]],
      @unlogged
    )

    product
    |> Changeset.change(status: :retired, retired_at: now)
    |> Repo.update!(@unlogged)

    audit!(access.gym.id, user.id, :member_product_retired, now, %{member_product_id: product.id})
    {:ok, product_view(fetch_product!(product.id))}
  end

  @doc "The gym's member product subscriptions, newest first (`view_member_product_subscriptions`)."
  @spec list_subscriptions(User.t(), term(), map()) ::
          {:ok, %{entries: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def list_subscriptions(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, access} <- Access.authorize(user, gym_id, :view_member_product_subscriptions),
         {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, MemberProductSubscription.statuses()) do
      rows =
        from(s in MemberProductSubscription,
          where: s.gym_id == ^access.gym.id,
          order_by: [desc: s.requested_at, desc: s.id],
          limit: ^(limit + 1),
          preload: [product_version: :product, price_version: []]
        )
        |> filter_status(status)
        |> Paging.seek(cursor, :requested_at, :desc)
        |> Repo.all(@unlogged)

      {page, next} = Paging.page(rows, limit, :requested_at)
      {:ok, %{entries: staff_subscription_views(page), next_cursor: next}}
    end
  end

  ## Member side

  @doc "The published products of the gym of the caller's own active membership."
  @spec list_offers(User.t(), term()) ::
          {:ok, [map()]} | {:error, :not_found | {:conflict, map()}}
  def list_offers(%User{} = user, member_id) do
    with {:ok, member} <- own_active(user, member_id) do
      products =
        Repo.all(
          from(p in MemberProduct,
            where: p.gym_id == ^member.gym_id and p.status == :active,
            order_by: [asc: p.inserted_at, asc: p.id],
            preload: [versions: ^versions_order()]
          ),
          @unlogged
        )

      {:ok,
       products
       |> Enum.map(&product_view/1)
       |> Enum.filter(& &1.published)
       |> Enum.map(&Map.drop(&1, [:versions, :draft]))}
    end
  end

  @doc """
  The caller asks for a product of their own active membership's gym
  (`product_version_id`, `price_version_id`, `client_request_id`): a
  `pending_activation` intent. The version must be the product's published
  one and the price its current price in that currency (`409` otherwise).
  """
  @spec request_subscription(User.t(), Session.t(), term(), map()) ::
          {:ok, {map(), :created | :existing}} | {:error, error()}
  def request_subscription(%User{} = user, %Session{} = session, member_id, attrs)
      when is_map(attrs) do
    with {:ok, fields} <- request_fields(attrs) do
      Repo.transaction(fn -> request_in(user, session, member_id, fields) end, @unlogged)
    end
  end

  defp request_in(user, session, member_id, fields) do
    with :ok <- Members.held(Accounts.hold_active_session(user, session)),
         {:ok, member} <- lock_own_member(user, member_id),
         :ok <- hit(user, @member_limit),
         {:ok, value} <- request_for(member, user, fields, Clock.utc_now()) do
      value
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The same key again: the same intent (200); for another member or price: 409.
  defp request_for(member, user, fields, now) do
    case Repo.one(
           from(s in MemberProductSubscription,
             where:
               s.gym_id == ^member.gym_id and s.client_request_id == ^fields.client_request_id
           ),
           @unlogged
         ) do
      %MemberProductSubscription{gym_member_id: id, price_version_id: price} = found
      when id == member.id and price == fields.price_version_id ->
        {:ok, {own_view(preload_sub(found)), :existing}}

      %MemberProductSubscription{} ->
        {:error, {:conflict, %{client_request_id: "reused"}}}

      nil ->
        insert_subscription(member, user, fields, now)
    end
  end

  @doc "The caller's own member product subscriptions, every gym, newest first."
  @spec list_mine(User.t(), map()) ::
          {:ok, %{entries: [map()], next_cursor: String.t() | nil}} | {:error, Changeset.t()}
  def list_mine(%User{} = user, params) when is_map(params) do
    with {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, MemberProductSubscription.statuses()) do
      rows =
        from(s in MemberProductSubscription,
          join: m in Member,
          on: m.id == s.gym_member_id,
          where: m.user_id == ^user.id,
          order_by: [desc: s.requested_at, desc: s.id],
          limit: ^(limit + 1),
          preload: [product_version: :product, price_version: []]
        )
        |> filter_status(status)
        |> Paging.seek(cursor, :requested_at, :desc)
        |> Repo.all(@unlogged)

      {page, next} = Paging.page(rows, limit, :requested_at)
      {:ok, %{entries: Enum.map(page, &own_view/1), next_cursor: next}}
    end
  end

  @doc """
  Cancels one of the caller's own subscriptions: an intent (or an active
  one) ends at once; repeating it returns it unchanged. No refund exists.
  """
  @spec cancel_mine(User.t(), Session.t(), term()) :: {:ok, map()} | {:error, error()}
  def cancel_mine(%User{} = user, %Session{} = session, subscription_id) do
    Repo.transaction(
      fn ->
        with :ok <- Members.held(Accounts.hold_active_session(user, session)),
             {:ok, subscription} <- lock_own_subscription(user, subscription_id),
             {:ok, cancelled} <-
               cancel_subscription(subscription, user.id, :requested_by_member, Clock.utc_now()) do
          own_view(preload_sub(cancelled))
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
  end

  @doc false
  # SF-101: an ending membership keeps no product subscription. Its current
  # ones (intents included) are cancelled with `membership_ended` inside the
  # transaction that ends it; nothing is refunded.
  @spec release_member!(Member.t(), Ecto.UUID.t() | nil, DateTime.t()) :: :ok
  def release_member!(%Member{id: member_id}, actor_user_id, now) do
    from(s in MemberProductSubscription,
      where:
        s.gym_member_id == ^member_id and
          s.status in [:pending_activation, :active, :cancellation_scheduled],
      order_by: [asc: s.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all(@unlogged)
    |> Enum.each(&({:ok, _} = cancel_subscription(&1, actor_user_id, :membership_ended, now)))
  end

  @doc """
  Activates a pending member subscription from a trusted provider's evidence
  (no HTTP endpoint; `SimpleFit.Billing.Activation`). Outside tests every
  call answers `{:error, :untrusted_provider}`.
  """
  @spec activate_subscription(term(), module(), term(), DateTime.t()) ::
          {:ok, MemberProductSubscription.t()} | {:error, term()}
  def activate_subscription(subscription_id, provider, payload, now \\ Clock.utc_now()) do
    Repo.transaction(
      fn ->
        with {:ok, id} <- Ecto.UUID.cast(subscription_id),
             %MemberProductSubscription{status: :pending_activation} = subscription <-
               Repo.one(
                 from(s in MemberProductSubscription, where: s.id == ^id, lock: "FOR UPDATE"),
                 @unlogged
               ),
             %Member{status: :active} <- Repo.get(Member, subscription.gym_member_id, @unlogged),
             {:ok, evidence} <-
               Activation.record(provider, payload, :member_product_subscription, now) do
          activated =
            subscription
            |> Changeset.change(
              status: :active,
              activation_evidence_id: evidence.id,
              activated_at: now,
              current_period_start: evidence.period_start,
              current_period_end: evidence.period_end,
              revision: subscription.revision + 1
            )
            |> Repo.update!(@unlogged)

          audit!(activated.gym_id, nil, :member_product_subscription_activated, now, %{
            member_product_subscription_id: activated.id,
            gym_member_id: activated.gym_member_id
          })

          activated
        else
          {:error, reason} ->
            Repo.rollback(reason)

          :error ->
            Repo.rollback(:not_found)

          nil ->
            Repo.rollback(:not_found)

          %MemberProductSubscription{status: status} ->
            Repo.rollback({:conflict, %{member_product_subscription: Atom.to_string(status)}})

          %Member{status: status} ->
            Repo.rollback({:conflict, %{gym_member: Atom.to_string(status)}})
        end
      end,
      @unlogged
    )
  end

  ## Steps

  defp staff_write(user, session, gym_id, fun) do
    Guarded.write(user, session, gym_id, :manage_member_products, @staff_limit, fn access ->
      fun.(access, Clock.utc_now())
    end)
  rescue
    error in Ecto.ConstraintError -> {:error, {:conflict, %{member_product: constraint(error)}}}
  end

  defp constraint(%Ecto.ConstraintError{constraint: name}) do
    cond do
      String.contains?(name, "key") -> "key_taken"
      String.contains?(name, "draft") -> "draft_exists"
      true -> "conflict"
    end
  end

  defp hit(%User{id: user_id}, {bucket, count, seconds}),
    do: RateLimit.hit([{bucket, MemberSecrets.rate_limit_key("user", user_id), count, seconds}])

  defp insert_product(access, user, fields, now) do
    if Repo.exists?(
         from(p in MemberProduct, where: p.gym_id == ^access.gym.id and p.key == ^fields.key)
       ) do
      {:error, {:conflict, %{member_product: "key_taken"}}}
    else
      product =
        Repo.insert!(
          %MemberProduct{
            gym_id: access.gym.id,
            key: fields.key,
            product_type: fields.product_type,
            client_request_id: fields.client_request_id,
            created_by_user_id: user.id
          },
          @unlogged
        )

      version = insert_version!(product, fields, 1)
      price = insert_price!(version, fields.price, fields.client_request_id, 1, user)

      audit!(access.gym.id, user.id, :member_product_created, now, %{
        member_product_id: product.id,
        member_product_version_id: version.id,
        member_price_version_id: price.id
      })

      {:ok, {product_view(fetch_product!(product.id)), :created}}
    end
  end

  defp insert_version!(product, fields, number) do
    Repo.insert!(
      %MemberProductVersion{
        gym_id: product.gym_id,
        product_id: product.id,
        version: number,
        name: fields.name,
        description: fields.description,
        class_credits: fields.class_credits,
        validity_days: fields.validity_days
      },
      @unlogged
    )
  end

  defp insert_price!(version, %{currency: currency, amount_minor: minor}, key, sequence, user) do
    Repo.insert!(
      %MemberPriceVersion{
        gym_id: version.gym_id,
        product_version_id: version.id,
        currency: currency,
        amount_minor: minor,
        sequence: sequence,
        client_request_id: key,
        created_by_user_id: user.id
      },
      @unlogged
    )
  end

  # The same key again: the same product (200); for another key: 409.
  defp create_product_in(access, user, fields, now) do
    case Repo.one(
           from(p in MemberProduct,
             where:
               p.gym_id == ^access.gym.id and p.client_request_id == ^fields.client_request_id
           ),
           @unlogged
         ) do
      %MemberProduct{key: key} = product when key == fields.key ->
        {:ok, {product_view(fetch_product!(product.id)), :existing}}

      %MemberProduct{} ->
        {:error, {:conflict, %{client_request_id: "reused"}}}

      nil ->
        insert_product(access, user, fields, now)
    end
  end

  # The same key again: the same price (200); for another price: 409.
  defp add_price_in(access, user, product_id, version_id, fields, now) do
    with {:ok, product} <- lock_product(access.gym.id, product_id),
         :ok <- active_product(product),
         {:ok, version} <- lock_version(product, version_id) do
      price_for(access, user, product, version, fields, now)
    end
  end

  defp price_for(access, user, product, version, fields, now) do
    case Repo.one(
           from(p in MemberPriceVersion,
             where:
               p.gym_id == ^access.gym.id and p.client_request_id == ^fields.client_request_id
           ),
           @unlogged
         ) do
      %MemberPriceVersion{} = price ->
        same_price(price, version, fields, product)

      nil ->
        with :ok <- version_status(version, [:draft, :published]) do
          price =
            insert_price!(
              version,
              fields,
              fields.client_request_id,
              next_sequence(version, fields.currency),
              user
            )

          audit!(
            access.gym.id,
            user.id,
            :member_product_price_created,
            now,
            Map.put(version_ids(version), :member_price_version_id, price.id)
          )

          {:ok, {product_view(fetch_product!(product.id)), :created}}
        end
    end
  end

  defp same_price(price, version, fields, product) do
    if price.product_version_id == version.id and price.currency == fields.currency and
         price.amount_minor == fields.amount_minor,
       do: {:ok, {product_view(fetch_product!(product.id)), :existing}},
       else: {:error, {:conflict, %{client_request_id: "reused"}}}
  end

  defp insert_subscription(member, user, fields, now) do
    with {:ok, version, price} <- offer(member.gym_id, fields) do
      subscription =
        Repo.insert!(
          %MemberProductSubscription{
            gym_id: member.gym_id,
            gym_member_id: member.id,
            product_version_id: version.id,
            price_version_id: price.id,
            client_request_id: fields.client_request_id,
            requested_by_user_id: user.id,
            requested_at: now
          },
          @unlogged
        )

      audit!(member.gym_id, user.id, :member_product_subscription_requested, now, %{
        member_product_subscription_id: subscription.id,
        gym_member_id: member.id
      })

      {:ok, {own_view(preload_sub(subscription)), :created}}
    end
  end

  # The product's published version of an active product, at its current
  # price in that currency: what the member would agree to now.
  defp offer(gym_id, fields) do
    version =
      with %MemberProductVersion{} = version <-
             Repo.one(
               from(v in MemberProductVersion,
                 where: v.id == ^fields.product_version_id and v.gym_id == ^gym_id
               ),
               @unlogged
             ) do
        status =
          Repo.one!(
            from(p in MemberProduct,
              where: p.id == ^version.product_id,
              lock: "FOR SHARE",
              select: p.status
            ),
            @unlogged
          )

        {Repo.reload!(version, @unlogged), status}
      end

    with {%MemberProductVersion{} = version, :active} <- version || {nil, nil},
         :ok <- version_status(version, [:published]),
         %MemberPriceVersion{} = price <-
           Repo.one(
             from(p in MemberPriceVersion,
               where: p.id == ^fields.price_version_id and p.product_version_id == ^version.id
             ),
             @unlogged
           ),
         :ok <- current_price(price) do
      {:ok, version, price}
    else
      {nil, nil} -> {:error, :not_found}
      {%MemberProductVersion{}, :retired} -> {:error, {:conflict, %{member_product: "retired"}}}
      nil -> {:error, {:conflict, %{member_price_version: "not_found"}}}
      {:error, _} = error -> error
    end
  end

  defp current_price(price) do
    latest =
      Repo.one(
        from(p in MemberPriceVersion,
          where:
            p.product_version_id == ^price.product_version_id and p.currency == ^price.currency,
          select: max(p.sequence)
        ),
        @unlogged
      )

    if latest == price.sequence,
      do: :ok,
      else: {:error, {:conflict, %{member_price_version: "superseded"}}}
  end

  defp cancel_subscription(
         %MemberProductSubscription{status: :cancelled} = s,
         _actor,
         _why,
         _now
       ),
       do: {:ok, s}

  defp cancel_subscription(%MemberProductSubscription{status: :expired}, _actor, _why, _now),
    do: {:error, {:conflict, %{member_product_subscription: "expired"}}}

  defp cancel_subscription(%MemberProductSubscription{} = s, actor, why, now) do
    cancelled =
      s
      |> Changeset.change(
        status: :cancelled,
        cancel_mode: :immediate,
        cancel_reason: why,
        cancellation_requested_at: now,
        cancellation_effective_at: now,
        cancelled_by_user_id: actor,
        ended_at: now,
        revision: s.revision + 1
      )
      |> Repo.update!(@unlogged)

    audit!(s.gym_id, actor, :member_product_subscription_cancelled, now, %{
      member_product_subscription_id: s.id,
      gym_member_id: s.gym_member_id
    })

    {:ok, cancelled}
  end

  ## Params

  defp product_fields(attrs) do
    types = %{client_request_id: Ecto.UUID, key: :string, product_type: :string}

    changeset =
      {%{}, types}
      |> Changeset.cast(attrs, Map.keys(types))
      |> Changeset.validate_required(Map.keys(types))
      |> Changeset.validate_format(:key, ~r/\A[a-z][a-z0-9_]{1,39}\z/)
      |> Changeset.validate_inclusion(
        :product_type,
        Enum.map(MemberProduct.types(), &to_string/1)
      )
      |> Members.reject_unknown_fields(attrs, @product_fields)

    with {:ok, base} <- Changeset.apply_action(changeset, :validate),
         type = String.to_existing_atom(base.product_type),
         {:ok, content} <- content_fields(attrs, type, @product_fields) do
      {:ok,
       Map.merge(content, %{
         client_request_id: base.client_request_id,
         key: base.key,
         product_type: type
       })}
    end
  end

  defp version_fields(attrs, type) do
    with {:ok, %{client_request_id: key}} <-
           {%{}, %{client_request_id: Ecto.UUID}}
           |> Changeset.cast(attrs, [:client_request_id])
           |> Changeset.validate_required([:client_request_id])
           |> Changeset.apply_action(:validate),
         {:ok, content} <- content_fields(attrs, type, @version_fields) do
      {:ok, Map.put(content, :client_request_id, key)}
    end
  end

  # name, description, class_credits, validity_days and price, by product type.
  defp content_fields(attrs, type, allowed) do
    types = %{
      name: :string,
      description: :string,
      class_credits: :integer,
      validity_days: :integer
    }

    changeset =
      {%{description: nil, class_credits: nil, validity_days: nil}, types}
      |> Changeset.cast(attrs, Map.keys(types))
      |> Changeset.validate_required([:name])
      |> Changeset.validate_length(:name, min: 1, max: 80)
      |> Changeset.validate_length(:description, max: 500)
      |> Changeset.validate_number(:validity_days,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: 730
      )
      |> type_rules(type)
      |> Members.reject_unknown_fields(attrs, allowed)

    with {:ok, content} <- Changeset.apply_action(changeset, :validate),
         {:ok, price} <- nested_price(attrs) do
      credits = if type == :single_visit, do: 1, else: content.class_credits
      {:ok, %{content | class_credits: credits} |> Map.put(:price, price)}
    end
  end

  defp type_rules(changeset, :single_visit),
    do: Changeset.validate_number(changeset, :class_credits, equal_to: 1)

  defp type_rules(changeset, :class_pack) do
    changeset
    |> Changeset.validate_required([:class_credits, :validity_days])
    |> Changeset.validate_number(:class_credits,
      greater_than_or_equal_to: 2,
      less_than_or_equal_to: 500
    )
  end

  defp type_rules(changeset, :unlimited_period) do
    changeset
    |> Changeset.validate_required([:validity_days])
    |> then(fn cs ->
      if Changeset.get_field(cs, :class_credits),
        do:
          Changeset.add_error(cs, :class_credits, "must be empty for unlimited access",
            validation: :invalid
          ),
        else: cs
    end)
  end

  defp nested_price(%{"price" => price}) when is_map(price), do: money(price, ~w(currency amount))
  defp nested_price(%{price: price}) when is_map(price), do: money(price, ~w(currency amount))

  defp nested_price(_),
    do:
      {:error,
       Changeset.add_error(Changeset.change({%{}, %{price: :map}}), :price, "can't be blank",
         validation: :required
       )}

  defp price_fields(attrs) do
    with {:ok, %{client_request_id: key}} <-
           {%{}, %{client_request_id: Ecto.UUID}}
           |> Changeset.cast(attrs, [:client_request_id])
           |> Changeset.validate_required([:client_request_id])
           |> Members.reject_unknown_fields(attrs, @price_fields)
           |> Changeset.apply_action(:validate),
         {:ok, money} <-
           money(Map.drop(attrs, ["client_request_id", :client_request_id]), ~w(currency amount)) do
      {:ok, Map.put(money, :client_request_id, key)}
    end
  end

  # A currency and a decimal amount string, exactly (SimpleFit.Money).
  defp money(attrs, allowed) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    changeset =
      {%{}, %{currency: :string}}
      |> Changeset.cast(attrs, [:currency])
      |> Changeset.validate_required([:currency])
      |> Members.reject_unknown_fields(attrs, allowed)

    with {:ok, %{currency: currency}} <- Changeset.apply_action(changeset, :validate) do
      case Money.parse(Map.get(attrs, "amount"), currency) do
        {:ok, minor} -> {:ok, %{currency: currency, amount_minor: minor}}
        {:error, code} -> {:error, money_error(code)}
      end
    end
  end

  defp money_error(:invalid_currency),
    do: field(:currency, "is not a supported currency", :invalid_choice)

  defp money_error(:invalid_type), do: field(:amount, "must be a decimal string", :invalid_type)
  defp money_error(:negative), do: field(:amount, "must not be negative", :out_of_range)

  defp money_error(:too_precise),
    do: field(:amount, "is finer than the currency's minor unit", :invalid_format)

  defp money_error(:out_of_range), do: field(:amount, "is too large", :out_of_range)
  defp money_error(_), do: field(:amount, "is not a decimal amount", :invalid_format)

  defp field(name, message, validation),
    do:
      Changeset.add_error(Changeset.change({%{}, %{name => :string}}), name, message,
        validation: validation
      )

  defp request_fields(attrs) do
    types = %{
      product_version_id: Ecto.UUID,
      price_version_id: Ecto.UUID,
      client_request_id: Ecto.UUID
    }

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required(Map.keys(types))
    |> Members.reject_unknown_fields(attrs, @request_fields)
    |> Changeset.apply_action(:validate)
  end

  ## Rows

  defp fetch_product(gym_id, product_id) do
    with {:ok, id} <- Ecto.UUID.cast(product_id),
         %MemberProduct{} = product <-
           Repo.one(
             from(p in MemberProduct, where: p.id == ^id and p.gym_id == ^gym_id),
             @unlogged
           ) do
      {:ok, Repo.preload(product, [versions: versions_order()], @unlogged)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_product!(id),
    do:
      MemberProduct
      |> Repo.get!(id, @unlogged)
      |> Repo.preload([versions: versions_order()], @unlogged)

  defp versions_order,
    do:
      from(v in MemberProductVersion,
        order_by: [desc: v.version],
        preload: [
          prices: ^from(p in MemberPriceVersion, order_by: [asc: p.currency, desc: p.sequence])
        ]
      )

  defp lock_product(gym_id, product_id) do
    with {:ok, id} <- Ecto.UUID.cast(product_id),
         %MemberProduct{} = product <-
           Repo.one(
             from(p in MemberProduct,
               where: p.id == ^id and p.gym_id == ^gym_id,
               lock: "FOR UPDATE"
             ),
             @unlogged
           ) do
      {:ok, product}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_version(product, version_id) do
    with {:ok, id} <- Ecto.UUID.cast(version_id),
         %MemberProductVersion{} = version <-
           Repo.one(
             from(v in MemberProductVersion,
               where: v.id == ^id and v.product_id == ^product.id,
               lock: "FOR UPDATE"
             ),
             @unlogged
           ) do
      {:ok, version}
    else
      _ -> {:error, :not_found}
    end
  end

  defp active_product(%MemberProduct{status: :active}), do: :ok
  defp active_product(%MemberProduct{}), do: {:error, {:conflict, %{member_product: "retired"}}}

  defp no_draft(product) do
    if Repo.exists?(
         from(v in MemberProductVersion,
           where: v.product_id == ^product.id and v.status == :draft
         )
       ),
       do: {:error, {:conflict, %{member_product: "draft_exists"}}},
       else: :ok
  end

  defp next_version(product),
    do:
      (Repo.one(
         from(v in MemberProductVersion,
           where: v.product_id == ^product.id,
           select: max(v.version)
         )
       ) || 0) +
        1

  defp next_sequence(version, currency),
    do:
      (Repo.one(
         from(p in MemberPriceVersion,
           where: p.product_version_id == ^version.id and p.currency == ^currency,
           select: max(p.sequence)
         )
       ) || 0) + 1

  defp version_status(%MemberProductVersion{status: status}, allowed) do
    if status in allowed,
      do: :ok,
      else: {:error, {:conflict, %{member_product_version: Atom.to_string(status)}}}
  end

  defp priced(version) do
    if Repo.exists?(from(p in MemberPriceVersion, where: p.product_version_id == ^version.id)),
      do: :ok,
      else: {:error, {:conflict, %{member_product_version: "no_prices"}}}
  end

  defp own_active(user, member_id) do
    with {:ok, id} <- Ecto.UUID.cast(member_id),
         %Member{} = member <-
           Repo.one(from(m in Member, where: m.id == ^id and m.user_id == ^user.id), @unlogged) do
      active(member)
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_own_member(user, member_id) do
    with {:ok, id} <- Ecto.UUID.cast(member_id),
         %Member{gym_id: gym_id} <-
           Repo.one(from(m in Member, where: m.id == ^id and m.user_id == ^user.id), @unlogged),
         %Gym{setup_status: :completed} <- Access.lock_gym_shared!(gym_id),
         %Member{} = member <-
           Repo.one(from(m in Member, where: m.id == ^id, lock: "FOR SHARE"), @unlogged) do
      active(member)
    else
      _ -> {:error, :not_found}
    end
  end

  defp active(%Member{status: :active} = member), do: {:ok, member}

  defp active(%Member{status: status}),
    do: {:error, {:conflict, %{gym_member: Atom.to_string(status)}}}

  defp lock_own_subscription(user, subscription_id) do
    with {:ok, id} <- Ecto.UUID.cast(subscription_id),
         true <-
           Repo.exists?(
             from(s in MemberProductSubscription,
               join: m in Member,
               on: m.id == s.gym_member_id,
               where: s.id == ^id and m.user_id == ^user.id
             ),
             @unlogged
           ),
         %MemberProductSubscription{} = subscription <-
           Repo.one(
             from(s in MemberProductSubscription, where: s.id == ^id, lock: "FOR UPDATE"),
             @unlogged
           ) do
      {:ok, subscription}
    else
      _ -> {:error, :not_found}
    end
  end

  defp preload_sub(subscription),
    do: Repo.preload(subscription, [product_version: :product, price_version: []], @unlogged)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from(s in query, where: s.status == ^status)

  ## Views (amounts as decimal strings by the JSON layer: never a float)

  defp product_view(%MemberProduct{} = product) do
    published = Enum.find(product.versions, &(&1.status == :published))

    %{
      product_id: product.id,
      gym_id: product.gym_id,
      key: product.key,
      product_type: product.product_type,
      status: product.status,
      published: published && version_view(published),
      draft:
        product.versions |> Enum.find(&(&1.status == :draft)) |> then(&(&1 && version_view(&1))),
      versions: Enum.map(product.versions, &version_view/1),
      created_at: product.inserted_at,
      retired_at: product.retired_at
    }
  end

  defp version_view(%MemberProductVersion{} = version) do
    %{
      version_id: version.id,
      version: version.version,
      status: version.status,
      name: version.name,
      description: version.description,
      class_credits: version.class_credits,
      validity_days: version.validity_days,
      published_at: version.published_at,
      current_prices: current_prices(version.prices),
      prices: Enum.map(version.prices, &price_view/1)
    }
  end

  defp current_prices(prices) do
    prices
    |> Enum.group_by(& &1.currency)
    |> Enum.map(fn {_currency, rows} -> Enum.max_by(rows, & &1.sequence) end)
    |> Enum.sort_by(& &1.currency)
    |> Enum.map(&price_view/1)
  end

  defp price_view(%MemberPriceVersion{} = price),
    do: %{
      price_version_id: price.id,
      currency: price.currency,
      amount_minor: price.amount_minor,
      sequence: price.sequence,
      created_at: price.inserted_at
    }

  defp own_view(%MemberProductSubscription{} = s) do
    %{
      subscription_id: s.id,
      gym_id: s.gym_id,
      gym_member_id: s.gym_member_id,
      status: s.status,
      product: %{
        product_id: s.product_version.product_id,
        key: s.product_version.product.key,
        product_type: s.product_version.product.product_type,
        version_id: s.product_version.id,
        version: s.product_version.version,
        name: s.product_version.name,
        class_credits: s.product_version.class_credits,
        validity_days: s.product_version.validity_days
      },
      price: price_view(s.price_version),
      requested_at: s.requested_at,
      activated_at: s.activated_at,
      current_period_start: s.current_period_start,
      current_period_end: s.current_period_end,
      cancel_mode: s.cancel_mode,
      cancel_reason: s.cancel_reason,
      cancellation_requested_at: s.cancellation_requested_at,
      cancellation_effective_at: s.cancellation_effective_at,
      ended_at: s.ended_at
    }
  end

  defp staff_subscription_views(rows) do
    members =
      Repo.all(
        from(m in Member,
          where: m.id in ^Enum.map(rows, & &1.gym_member_id),
          select: {m.id, m.user_id}
        ),
        @unlogged
      )
      |> Map.new()

    names = members |> Map.values() |> Enum.reject(&is_nil/1) |> Accounts.short_names()

    Enum.map(rows, fn row ->
      row
      |> own_view()
      |> Map.put(:member_name, get_in(names, [Map.get(members, row.gym_member_id), :short_name]))
    end)
  end

  defp version_ids(version),
    do: %{member_product_id: version.product_id, member_product_version_id: version.id}

  defp audit!(gym_id, actor_id, event, now, ids) do
    Audit.record!(
      Map.merge(%{gym_id: gym_id, actor_user_id: actor_id, event_type: event}, ids),
      now
    )

    :telemetry.execute([:simple_fit, :gyms, :commerce], %{count: 1}, %{event: event})
    :ok
  end
end
