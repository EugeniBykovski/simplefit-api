defmodule SimpleFit.Billing.Subscriptions do
  @moduledoc """
  A gym's SimpleFit SaaS subscription (SF-101). The gym is the subscriber;
  its owner acts for it (`manage_billing`, owner only), and an ownership
  transfer moves that authority without touching the subscription.

  ## Lifecycle

  * **Intent** (`request/4`): the owner chooses a published plan version's
    priced (not quote) price version. The row is `pending_activation` and
    grants nothing. A `client_request_id` names one intent for ever (the
    same key again returns it, `200`; for another price, `409
    client_request_id: reused`). A gym has at most one current subscription
    (`409 saas_subscription: current_exists`). Unknown fields such as a
    `status`, a `receipt` or a `payment` are refused (`422`): a client can
    neither activate nor pay.
  * **Activation** (`activate/4`, no HTTP endpoint): only from evidence a
    trusted provider verified (`SimpleFit.Billing.Activation`); none is
    configured outside tests, so nothing activates.
  * **Cancellation** (`cancel/5`): `immediate` ends it now (a pending intent
    is always cancelled at once); `period_end` schedules the end at the
    current period's end (`cancellation_scheduled`). Repeating the same
    request returns the subscription unchanged (`200`, one audit event).
    No refund, proration or invoice is computed or recorded.
  * **Period end** (`advance/1`): an active subscription whose period ended
    becomes `expired` (periods are never created without verified
    evidence), and a scheduled cancellation becomes `cancelled` when it
    takes effect. SF-102: a subscription whose Stripe subscription is still
    live is left to reconciliation (a renewal may be in its retry window;
    entitlements already lapse at the period end).
  * **Provider transitions** (SF-102, `*_locked`): activation, renewal,
    a provider-scheduled or withdrawn cancellation and a provider end, all
    from reconciled provider state inside the reconciliation transaction.

  Concurrent requests serialize on the gym row (the gym write transaction)
  and the subscription row (`FOR UPDATE`): one outcome, one event.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.{Session, User}

  alias SimpleFit.{Clock, Gyms, Repo}

  alias SimpleFit.Billing.{
    Activation,
    GymSubscription,
    PlanVersion,
    PriceVersion,
    SubscriptionPeriod
  }

  alias SimpleFit.Billing.Stripe.SubscriptionLink

  @unlogged [log: false]
  @request_fields ["plan_version_id", "price_version_id", "client_request_id"]
  @cancel_fields ["mode"]
  @current [:pending_activation, :active, :cancellation_scheduled]
  @provider_final [:canceled, :incomplete_expired]

  @type error ::
          :not_found
          | :forbidden
          | :session_revoked
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | Changeset.t()

  @doc "The gym's SaaS subscriptions, newest first (`manage_billing`)."
  @spec list(User.t(), term()) :: {:ok, [GymSubscription.t()]} | {:error, :not_found | :forbidden}
  def list(%User{} = user, gym_id) do
    with {:ok, access} <- Gyms.authorize(user, gym_id, :manage_billing) do
      {:ok,
       Repo.all(
         from(s in GymSubscription,
           where: s.gym_id == ^access.gym.id,
           order_by: [desc: s.requested_at, desc: s.id],
           preload: [plan_version: :plan, price_version: []]
         ),
         @unlogged
       )}
    end
  end

  @doc "Records a subscription intent (see the moduledoc)."
  @spec request(User.t(), Session.t(), term(), map()) ::
          {:ok, {GymSubscription.t(), :created | :existing}} | {:error, error()}
  def request(%User{} = user, %Session{} = session, gym_id, attrs) when is_map(attrs) do
    with {:ok, fields} <- request_fields(attrs) do
      Gyms.billing_write(user, session, gym_id, :manage_billing, &request_in(&1, user, fields))
    end
  end

  @doc "Cancels the gym's subscription `subscription_id` (see the moduledoc)."
  @spec cancel(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, GymSubscription.t()} | {:error, error()}
  def cancel(%User{} = user, %Session{} = session, gym_id, subscription_id, attrs)
      when is_map(attrs) do
    with {:ok, mode} <- cancel_mode(attrs) do
      Gyms.billing_write(
        user,
        session,
        gym_id,
        :manage_billing,
        &cancel_in(&1, user, subscription_id, mode)
      )
    end
  end

  @doc """
  Activates a pending subscription from a trusted provider's verified
  evidence (no HTTP endpoint; see `SimpleFit.Billing.Activation`). Outside
  tests every call answers `{:error, :untrusted_provider}`.
  """
  @spec activate(term(), module(), term(), DateTime.t()) ::
          {:ok, GymSubscription.t()} | {:error, atom() | {:conflict, map()}}
  def activate(subscription_id, provider, payload, now \\ Clock.utc_now()) do
    Repo.transaction(
      fn ->
        with {:ok, subscription} <- lock_any(subscription_id),
             {:ok, activated} <- activate_locked(subscription, provider, payload, now) do
          activated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
    |> tap(&emit(:activation, &1))
  end

  ## Provider-backed transitions (SF-102)
  #
  # Called by `SimpleFit.Billing.Reconciliation` inside its transaction, with
  # the subscription locked (`lock_for_provider/1`), from provider state it
  # fetched from the provider's API. None is reachable over HTTP.

  @doc """
  Locks any gym's subscription for reconciliation (inside a transaction), in
  the gym write lock order: the gym row `FOR SHARE` first, then the
  subscription `FOR UPDATE`. (Locking the subscription first deadlocked
  against an owner's cancellation, which holds the gym row, once
  reconciliation wrote a row referencing the gym.)
  """
  @spec lock_for_provider(term()) :: {:ok, GymSubscription.t()} | {:error, :not_found}
  def lock_for_provider(subscription_id) do
    true = Repo.in_transaction?()

    with {:ok, id} <- Ecto.UUID.cast(subscription_id),
         gym_id when is_binary(gym_id) <-
           Repo.one(from(s in GymSubscription, where: s.id == ^id, select: s.gym_id), @unlogged),
         :ok <- Gyms.lock_gym_shared(gym_id) do
      lock_any(id)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Activates a locked pending subscription from verified evidence (the
  SF-101 activation, inside the caller's transaction).
  """
  @spec activate_locked(GymSubscription.t(), module(), term(), DateTime.t()) ::
          {:ok, GymSubscription.t()} | {:error, atom() | {:conflict, map()}}
  def activate_locked(%GymSubscription{} = subscription, provider, payload, now) do
    with :ok <- pending(subscription),
         {:ok, evidence} <- Activation.record(provider, payload, :saas_subscription, now) do
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

      insert_period!(activated, evidence, :activation)
      audit!(activated, nil, :saas_subscription_activated, now)
      {:ok, activated}
    end
  end

  @doc """
  Renews a locked active subscription for a later paid period from verified
  evidence: a `renewal` period row and the new current period. A period
  that does not extend the current one is refused (`:stale_period`).
  """
  @spec renew_locked(GymSubscription.t(), module(), term(), DateTime.t()) ::
          {:ok, GymSubscription.t()} | {:error, atom() | {:conflict, map()}}
  def renew_locked(%GymSubscription{status: :active} = subscription, provider, payload, now) do
    with {:ok, %{period_end: ends}} <- provider.verify(payload),
         :ok <- later(ends, subscription.current_period_end),
         {:ok, evidence} <- Activation.record(provider, payload, :saas_subscription, now) do
      renewed =
        subscription
        |> Changeset.change(
          current_period_start: evidence.period_start,
          current_period_end: evidence.period_end,
          revision: subscription.revision + 1
        )
        |> Repo.update!(@unlogged)

      insert_period!(renewed, evidence, :renewal)
      audit!(renewed, nil, :saas_subscription_renewed, now)
      {:ok, renewed}
    end
  end

  def renew_locked(%GymSubscription{status: status}, _provider, _payload, _now),
    do: {:error, {:conflict, %{saas_subscription: Atom.to_string(status)}}}

  @doc """
  A cancellation the provider scheduled at `effective_at` (the end of the
  paid period). Already scheduled: unchanged. A cancellation requested
  outside SimpleFit records `provider_initiated`.
  """
  @spec schedule_by_provider_locked(GymSubscription.t(), DateTime.t(), DateTime.t()) ::
          {:ok, GymSubscription.t()}
  def schedule_by_provider_locked(%GymSubscription{status: :active} = s, effective_at, now) do
    scheduled =
      s
      |> Changeset.change(
        status: :cancellation_scheduled,
        cancel_mode: :period_end,
        cancel_reason: :provider_initiated,
        cancellation_requested_at: now,
        cancellation_effective_at: effective_at,
        revision: s.revision + 1
      )
      |> Repo.update!(@unlogged)

    audit!(scheduled, nil, :saas_subscription_cancellation_scheduled, now)
    {:ok, scheduled}
  end

  def schedule_by_provider_locked(%GymSubscription{} = s, _effective_at, _now), do: {:ok, s}

  @doc """
  A scheduled cancellation the provider withdrew: the subscription is active
  again (the one SF-102 transition `cancellation_scheduled -> active`).
  """
  @spec reactivate_locked(GymSubscription.t(), DateTime.t()) :: {:ok, GymSubscription.t()}
  def reactivate_locked(%GymSubscription{status: :cancellation_scheduled} = s, now) do
    active =
      s
      |> Changeset.change(
        status: :active,
        cancel_mode: nil,
        cancel_reason: nil,
        cancellation_requested_at: nil,
        cancellation_effective_at: nil,
        cancelled_by_user_id: nil,
        revision: s.revision + 1
      )
      |> Repo.update!(@unlogged)

    audit!(active, nil, :saas_subscription_reactivated, now)
    {:ok, active}
  end

  def reactivate_locked(%GymSubscription{} = s, _now), do: {:ok, s}

  @doc """
  The provider ended the subscription: `:expired` (unpaid, its period
  ended) or `:cancelled` (a cancellation took effect; a scheduled one keeps
  its reason, otherwise `provider_initiated`). A pending intent is
  cancelled. Final subscriptions are unchanged.
  """
  @spec end_by_provider_locked(GymSubscription.t(), :cancelled | :expired, DateTime.t()) ::
          {:ok, GymSubscription.t()}
  def end_by_provider_locked(%GymSubscription{status: status} = s, _outcome, _now)
      when status in [:cancelled, :expired],
      do: {:ok, s}

  def end_by_provider_locked(%GymSubscription{status: status} = s, :expired, now)
      when status in [:active, :cancellation_scheduled] do
    finish(s, :expired, nil, now)
    {:ok, Repo.reload!(s, @unlogged)}
  end

  def end_by_provider_locked(%GymSubscription{} = s, _outcome, now) do
    cancelled =
      s
      |> Changeset.change(
        status: :cancelled,
        cancel_mode: s.cancel_mode || :immediate,
        cancel_reason: s.cancel_reason || :provider_initiated,
        cancellation_requested_at: s.cancellation_requested_at || now,
        cancellation_effective_at: now,
        ended_at: now,
        revision: s.revision + 1
      )
      |> Repo.update!(@unlogged)

    audit!(cancelled, nil, :saas_subscription_cancelled, now)
    {:ok, cancelled}
  end

  @doc "Records a provider-side billing event on the gym's audit trail (ids only)."
  @spec audit_billing!(GymSubscription.t(), atom(), Ecto.UUID.t() | nil, DateTime.t()) :: :ok
  def audit_billing!(%GymSubscription{} = s, event, record_id, now) do
    Gyms.record_commerce_event!(
      %{
        gym_id: s.gym_id,
        actor_user_id: nil,
        event_type: event,
        saas_subscription_id: s.id,
        billing_record_id: record_id
      },
      now
    )

    emit(event, {:ok, s})
  end

  defp later(ends, current) do
    if DateTime.compare(ends, current) == :gt, do: :ok, else: {:error, :stale_period}
  end

  defp insert_period!(subscription, evidence, source) do
    Repo.insert!(
      %SubscriptionPeriod{
        gym_id: subscription.gym_id,
        subscription_id: subscription.id,
        period_start: evidence.period_start,
        period_end: evidence.period_end,
        source: source,
        activation_evidence_id: evidence.id
      },
      @unlogged
    )
  end

  @doc """
  Ends what is due at `now`: active subscriptions whose period ended expire
  (no renewal source exists), scheduled cancellations take effect. Returns
  how many changed.
  """
  @spec advance(DateTime.t()) :: {:ok, non_neg_integer()}
  def advance(now \\ Clock.utc_now()) do
    ids =
      Repo.all(
        from(s in GymSubscription,
          left_join: l in SubscriptionLink,
          on: l.subscription_id == s.id and l.provider_status not in ^@provider_final,
          where:
            is_nil(l.id) and
              ((s.status == :active and s.current_period_end <= ^now) or
                 (s.status == :cancellation_scheduled and s.cancellation_effective_at <= ^now)),
          select: s.id
        ),
        @unlogged
      )

    {:ok, Enum.count(ids, &(advance_one(&1, now) == :changed))}
  end

  defp advance_one(id, now) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          Repo.one(from(s in GymSubscription, where: s.id == ^id, lock: "FOR UPDATE"), @unlogged)
          |> advance_locked(now)
        end,
        @unlogged
      )

    result
  end

  defp advance_locked(%GymSubscription{status: :active, current_period_end: ends} = s, now),
    do:
      if(DateTime.compare(ends, now) == :gt, do: :unchanged, else: finish(s, :expired, nil, now))

  defp advance_locked(
         %GymSubscription{status: :cancellation_scheduled, cancellation_effective_at: at} = s,
         now
       ),
       do:
         if(DateTime.compare(at, now) == :gt,
           do: :unchanged,
           else: finish(s, :cancelled, nil, now)
         )

  defp advance_locked(_subscription, _now), do: :unchanged

  defp finish(subscription, status, actor_id, now) do
    ended =
      subscription
      |> Changeset.change(status: status, ended_at: now, revision: subscription.revision + 1)
      |> Repo.update!(@unlogged)

    event =
      if status == :expired, do: :saas_subscription_expired, else: :saas_subscription_cancelled

    audit!(ended, actor_id, event, now)
    :changed
  end

  ## Steps

  # The same key again: the same intent (200); for another price: 409.
  defp request_in(access, user, fields) do
    case existing(access.gym.id, fields.client_request_id) do
      %GymSubscription{price_version_id: price_id} = found
      when price_id == fields.price_version_id ->
        {:ok, {preload(found), :existing}}

      %GymSubscription{} ->
        {:error, {:conflict, %{client_request_id: "reused"}}}

      nil ->
        create(access, user, fields, Clock.utc_now())
    end
  end

  defp cancel_in(access, user, subscription_id, mode) do
    with {:ok, subscription} <- lock(access.gym.id, subscription_id) do
      transition_cancel(subscription, mode, user.id, Clock.utc_now())
    end
  end

  defp request_fields(attrs) do
    types = %{
      plan_version_id: Ecto.UUID,
      price_version_id: Ecto.UUID,
      client_request_id: Ecto.UUID
    }

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required(Map.keys(types))
    |> reject_unknown(attrs, @request_fields)
    |> Changeset.apply_action(:validate)
  end

  defp cancel_mode(attrs) do
    {%{}, %{mode: :string}}
    |> Changeset.cast(attrs, [:mode])
    |> Changeset.validate_required([:mode])
    |> Changeset.validate_inclusion(:mode, ["immediate", "period_end"])
    |> reject_unknown(attrs, @cancel_fields)
    |> Changeset.apply_action(:validate)
    |> case do
      {:ok, %{mode: mode}} -> {:ok, String.to_existing_atom(mode)}
      error -> error
    end
  end

  # Any field outside `allowed` is refused under its own name, without
  # creating atoms or echoing its value (a `status`, `receipt` or `payment`
  # field is refused like any other).
  defp reject_unknown(changeset, attrs, allowed) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a permitted field", []}} | acc.errors], valid?: false}
    end)
  end

  defp existing(gym_id, key),
    do:
      Repo.one(
        from(s in GymSubscription, where: s.gym_id == ^gym_id and s.client_request_id == ^key),
        @unlogged
      )

  defp create(access, user, fields, now) do
    with {:ok, price} <- offered(fields.plan_version_id, fields.price_version_id),
         :ok <- no_current(access.gym.id) do
      subscription =
        %GymSubscription{
          gym_id: access.gym.id,
          plan_version_id: price.plan_version_id,
          price_version_id: price.id,
          client_request_id: fields.client_request_id,
          requested_by_user_id: user.id,
          requested_at: now
        }
        |> Repo.insert!(@unlogged)

      audit!(subscription, user.id, :saas_subscription_requested, now)
      {:ok, {preload(subscription), :created}}
    end
  end

  # A published version's priced (not quote) price, read under a share lock
  # so a concurrent retirement commits before or after.
  defp offered(plan_version_id, price_version_id) do
    status =
      Repo.one(
        from(v in PlanVersion,
          where: v.id == ^plan_version_id,
          lock: "FOR SHARE",
          select: v.status
        ),
        @unlogged
      )

    price =
      Repo.one(
        from(p in PriceVersion,
          where: p.id == ^price_version_id and p.plan_version_id == ^plan_version_id
        ),
        @unlogged
      )

    case {price, status} do
      {nil, _} ->
        {:error, {:conflict, %{saas_price_version: "not_found"}}}

      {_price, status} when status != :published ->
        {:error, {:conflict, %{saas_plan_version: Atom.to_string(status)}}}

      {%PriceVersion{pricing: :quote_required}, _} ->
        {:error, {:conflict, %{saas_price_version: "quote_required"}}}

      {%PriceVersion{} = price, :published} ->
        {:ok, price}
    end
  end

  defp no_current(gym_id) do
    if Repo.exists?(
         from(s in GymSubscription, where: s.gym_id == ^gym_id and s.status in ^@current)
       ),
       do: {:error, {:conflict, %{saas_subscription: "current_exists"}}},
       else: :ok
  end

  defp lock(gym_id, subscription_id) do
    with {:ok, id} <- Ecto.UUID.cast(subscription_id),
         %GymSubscription{} = subscription <-
           Repo.one(
             from(s in GymSubscription,
               where: s.id == ^id and s.gym_id == ^gym_id,
               lock: "FOR UPDATE"
             ),
             @unlogged
           ) do
      {:ok, subscription}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_any(subscription_id) do
    with {:ok, id} <- Ecto.UUID.cast(subscription_id),
         %GymSubscription{} = subscription <-
           Repo.one(from(s in GymSubscription, where: s.id == ^id, lock: "FOR UPDATE"), @unlogged) do
      {:ok, subscription}
    else
      _ -> {:error, :not_found}
    end
  end

  defp pending(%GymSubscription{status: :pending_activation}), do: :ok

  defp pending(%GymSubscription{status: status}),
    do: {:error, {:conflict, %{saas_subscription: Atom.to_string(status)}}}

  # Idempotent: the outcome a request asks for, once.
  defp transition_cancel(%GymSubscription{status: :cancelled} = s, _mode, _actor, _now),
    do: {:ok, preload(s)}

  defp transition_cancel(%GymSubscription{status: :expired}, _mode, _actor, _now),
    do: {:error, {:conflict, %{saas_subscription: "expired"}}}

  defp transition_cancel(
         %GymSubscription{status: :cancellation_scheduled} = s,
         :period_end,
         _actor,
         _now
       ),
       do: {:ok, preload(s)}

  defp transition_cancel(%GymSubscription{status: status} = s, mode, actor, now)
       when status == :pending_activation or mode == :immediate do
    cancelled =
      s
      |> Changeset.change(
        status: :cancelled,
        cancel_mode: :immediate,
        cancel_reason: :requested_by_gym,
        cancellation_requested_at: s.cancellation_requested_at || now,
        cancellation_effective_at: now,
        cancelled_by_user_id: actor,
        ended_at: now,
        revision: s.revision + 1
      )
      |> Repo.update!(@unlogged)

    audit!(cancelled, actor, :saas_subscription_cancelled, now)
    {:ok, preload(cancelled)}
  end

  defp transition_cancel(%GymSubscription{status: :active} = s, :period_end, actor, now) do
    scheduled =
      s
      |> Changeset.change(
        status: :cancellation_scheduled,
        cancel_mode: :period_end,
        cancel_reason: :requested_by_gym,
        cancellation_requested_at: now,
        cancellation_effective_at: s.current_period_end,
        cancelled_by_user_id: actor,
        revision: s.revision + 1
      )
      |> Repo.update!(@unlogged)

    audit!(scheduled, actor, :saas_subscription_cancellation_scheduled, now)
    {:ok, preload(scheduled)}
  end

  defp preload(subscription),
    do: Repo.preload(subscription, [plan_version: :plan, price_version: []], @unlogged)

  defp audit!(subscription, actor_id, event, now) do
    Gyms.record_commerce_event!(
      %{
        gym_id: subscription.gym_id,
        actor_user_id: actor_id,
        event_type: event,
        saas_subscription_id: subscription.id
      },
      now
    )

    emit(event, {:ok, subscription})
  end

  # Outcomes only: no gym, user, price or provider reference.
  defp emit(event, result) do
    outcome =
      case result do
        {:ok, _} -> :ok
        {:error, {:conflict, _}} -> :conflict
        {:error, reason} when is_atom(reason) -> reason
        _ -> :error
      end

    :telemetry.execute([:simple_fit, :billing, :subscription], %{count: 1}, %{
      event: event,
      outcome: outcome
    })

    :ok
  end
end
