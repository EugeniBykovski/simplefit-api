defmodule SimpleFit.Entitlements do
  @moduledoc """
  Backend-owned commercial entitlements (SF-101): what a gym's SimpleFit
  plan, or a member's product, includes. Never a client flag, and never an
  authorization: a gym's plan grants no staff permission (the Gym RBAC
  matrix decides who may act), and a member's product grants no staff role.

  ## Fail closed

  A feature is entitled only through a subscription that is `active` (or
  `cancellation_scheduled`, which stays in force until its effective date)
  **with verified activation evidence**, inside its current paid period, and
  whose plan version includes the feature. Anything else is denied:
  a pending intent, a cancelled or expired subscription, a period that has
  ended, a feature the plan does not include, or an unknown feature key.
  Nothing a client sends changes the result.

  ## Not enforced yet

  No SimpleFit endpoint gates on an entitlement: the SF-83 to SF-100 gym
  features stay available to every gym until a commercial rollout and
  grandfathering policy are approved (`enforced: false` in the projection).
  Booking a class needs no product either (`class_admission/3` answers
  `:not_required`): SF-99 eligibility is unchanged.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.Billing.{GymSubscription, PlanEntitlement}
  alias SimpleFit.{Clock, Gyms, Repo}
  alias SimpleFit.Entitlements.Features

  @unlogged [log: false]
  @in_force [:active, :cancellation_scheduled]

  @type decision ::
          {:entitled, %{subscription_id: Ecto.UUID.t(), quantity_limit: pos_integer() | nil}}
          | {:denied,
             :unknown_feature
             | :no_subscription
             | :pending_activation
             | :not_in_force
             | :not_in_plan}

  @doc """
  The gym's decision for one feature key at `now` (see the moduledoc).
  Emits telemetry with the key and the outcome only.
  """
  @spec gym_feature(Ecto.UUID.t(), String.t(), DateTime.t()) :: decision()
  def gym_feature(gym_id, key, now \\ Clock.utc_now()) do
    decision =
      if Features.known?(key),
        do: decide(subscription_in_force(gym_id, now), current(gym_id), key),
        else: {:denied, :unknown_feature}

    :telemetry.execute([:simple_fit, :entitlements, :evaluated], %{count: 1}, %{
      feature: if(Features.known?(key), do: key, else: "unknown"),
      outcome: elem(decision, 0)
    })

    decision
  end

  @doc """
  The gym's entitlement projection for its staff (`view_workspace`): every
  registered feature with its decision, the subscription it comes from and
  whether anything enforces it (nothing does yet).
  """
  @spec gym_projection(User.t(), term(), DateTime.t()) ::
          {:ok, %{subscription: map() | nil, features: [map()]}}
          | {:error, :not_found | :forbidden}
  def gym_projection(%User{} = user, gym_id, now \\ Clock.utc_now()) do
    with {:ok, access} <- Gyms.authorize(user, gym_id, :view_workspace) do
      gym = access.gym.id
      in_force = subscription_in_force(gym, now)
      latest = current(gym)

      features =
        Enum.map(Features.all(), fn feature ->
          {status, detail} = decide(in_force, latest, feature.key)

          Map.merge(feature, %{
            status: status,
            reason: if(status == :denied, do: detail),
            quantity_limit: if(status == :entitled, do: detail.quantity_limit)
          })
        end)

      {:ok,
       %{
         subscription:
           latest &&
             %{subscription_id: latest.id, status: latest.status, in_force: in_force != nil},
         features: features
       }}
    end
  end

  @doc """
  Whether a member needs a product entitlement to book `occurrence_id`. No
  class requires one: SF-99 eligibility (an active membership and a bookable
  class) is the whole rule until the commerce rollout approves product-only
  classes, so this always answers `:not_required` and nothing is debited.
  """
  @spec class_admission(term(), term(), DateTime.t()) :: :not_required
  def class_admission(_gym_member_id, _occurrence_id, _now \\ Clock.utc_now()), do: :not_required

  # The gym's subscription in force at `now`: active (or scheduled to cancel
  # later) with verified evidence and `now` inside its paid period.
  defp subscription_in_force(gym_id, now) do
    Repo.one(
      from(s in GymSubscription,
        where:
          s.gym_id == ^gym_id and s.status in ^@in_force and not is_nil(s.activation_evidence_id) and
            s.current_period_start <= ^now and s.current_period_end > ^now,
        limit: 1
      ),
      @unlogged
    )
  end

  defp current(gym_id) do
    Repo.one(
      from(s in GymSubscription,
        where: s.gym_id == ^gym_id,
        order_by: [desc: s.requested_at, desc: s.id],
        limit: 1
      ),
      @unlogged
    )
  end

  defp decide(nil, nil, _key), do: {:denied, :no_subscription}

  defp decide(nil, %GymSubscription{status: :pending_activation}, _key),
    do: {:denied, :pending_activation}

  defp decide(nil, %GymSubscription{}, _key), do: {:denied, :not_in_force}

  defp decide(%GymSubscription{} = subscription, _latest, key) do
    case Repo.one(
           from(e in PlanEntitlement,
             where: e.plan_version_id == ^subscription.plan_version_id and e.feature_key == ^key
           ),
           @unlogged
         ) do
      nil ->
        {:denied, :not_in_plan}

      %PlanEntitlement{quantity_limit: limit} ->
        {:entitled, %{subscription_id: subscription.id, quantity_limit: limit}}
    end
  end
end
