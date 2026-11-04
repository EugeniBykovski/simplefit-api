defmodule SimpleFit.Gyms.GoLive do
  @moduledoc """
  Go-live readiness of a gym (SF-103, OG14; ADR 0026 amendment SF-103),
  derived on every read from the gym's own records. Internal to
  `SimpleFit.Gyms`. Nothing here is stored, settable by a client or
  computed by one.

  Each check names its stable key, its status (`passed`, `failed`,
  `pending`, `blocked` by an external decision, `unavailable` because its
  feature does not exist), its requiredness under policy
  `#{"sf103-golive-1"}` (`required`, `recommended`, `optional`, `future`),
  a reason code, the domain it reads and, where the owner can act, an
  action key.

  `prerequisites_met` is true only when every required check passes; it is
  re-derived on each read, so a revoked verification makes it false at
  once (fail closed). It never publishes anything: **publication is
  unavailable** because SimpleFit has no approved public gym surface or
  publishing policy (D-G11, public half), so the answer always carries
  `publication: unavailable`.

  Facts, not proxies: a scheduled class is a timetable fact, a staff
  invitation is not staff (an active staff membership is), a join request
  is not a member, a pending application is not a verification, and a
  SimpleFit plan or Stripe capability is none of these.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.Billing.Connect
  alias SimpleFit.{Clock, Repo}

  alias SimpleFit.Gyms.{
    Access,
    ClassOccurrence,
    Gym,
    GymLocation,
    Member,
    MemberProduct,
    MemberProductVersion,
    StaffMembership,
    Verification
  }

  @unlogged [log: false]
  @policy_version "sf103-golive-1"

  @type status :: :passed | :failed | :pending | :blocked | :unavailable
  @type requiredness :: :required | :recommended | :optional | :future
  @type action ::
          :open_verification
          | :open_locations
          | :open_timetable
          | :open_staff
          | :open_members
          | :open_memberships

  @type check :: %{
          key: atom(),
          status: status(),
          requiredness: requiredness(),
          reason_code: atom(),
          action: action() | nil,
          source: atom()
        }

  @type readiness :: %{
          gym_id: Ecto.UUID.t(),
          policy_version: String.t(),
          evaluated_at: DateTime.t(),
          prerequisites_met: boolean(),
          checks: [check()],
          publication: %{status: :unavailable, reason_code: atom()}
        }

  @keys [
    :setup_completed,
    :primary_location,
    :business_verification,
    :upcoming_class,
    :staff,
    :members,
    :member_products,
    :member_payments,
    :public_profile,
    :community_settings
  ]

  @doc "The check keys, in display order."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "The readiness policy version."
  @spec policy_version() :: String.t()
  def policy_version, do: @policy_version

  @doc "The go-live readiness of a gym, for its owner and managers (`view_go_live`)."
  @spec get(User.t(), term()) :: {:ok, readiness()} | {:error, :not_found | :forbidden}
  def get(%User{} = user, gym_id) do
    with {:ok, %{gym: gym}} <- Access.authorize(user, gym_id, :view_go_live) do
      {:ok, evaluate(gym, now())}
    end
  end

  @doc false
  @spec evaluate(Gym.t(), DateTime.t()) :: readiness()
  def evaluate(%Gym{} = gym, now) do
    checks = Enum.map(@keys, &check(&1, gym, now))

    %{
      gym_id: gym.id,
      policy_version: @policy_version,
      evaluated_at: now,
      prerequisites_met:
        Enum.all?(checks, &(&1.requiredness != :required or &1.status == :passed)),
      checks: checks,
      publication: %{status: :unavailable, reason_code: :public_surface_not_available}
    }
  end

  defp check(:setup_completed, gym, _now) do
    if gym.setup_status == :completed,
      do: item(:setup_completed, :passed, :required, :setup_completed, nil, :gym_setup),
      else: item(:setup_completed, :failed, :required, :setup_incomplete, nil, :gym_setup)
  end

  defp check(:primary_location, gym, _now) do
    located? =
      exists?(
        from(l in GymLocation,
          where: l.gym_id == ^gym.id and l.is_primary and is_nil(l.archived_at)
        )
      )

    if located?,
      do: item(:primary_location, :passed, :required, :location_set, nil, :gym_setup),
      else:
        item(
          :primary_location,
          :failed,
          :required,
          :location_missing,
          :open_locations,
          :gym_setup
        )
  end

  defp check(:business_verification, gym, _now) do
    {status, reason} =
      case Verification.status(gym.id) do
        :approved -> {:passed, :approved}
        :submitted -> {:pending, :in_review}
        other -> {:failed, other}
      end

    item(
      :business_verification,
      status,
      :required,
      reason,
      :open_verification,
      :business_verification
    )
  end

  defp check(:upcoming_class, gym, now) do
    scheduled? =
      exists?(
        from(o in ClassOccurrence,
          where: o.gym_id == ^gym.id and o.status == :scheduled and o.starts_at > ^now
        )
      )

    if scheduled?,
      do:
        item(
          :upcoming_class,
          :passed,
          :recommended,
          :class_scheduled,
          :open_timetable,
          :timetable
        ),
      else:
        item(
          :upcoming_class,
          :failed,
          :recommended,
          :no_upcoming_class,
          :open_timetable,
          :timetable
        )
  end

  defp check(:staff, gym, _now) do
    staffed? =
      exists?(
        from(m in StaffMembership,
          where: m.gym_id == ^gym.id and m.status == :active and m.role != :owner
        )
      )

    if staffed?,
      do: item(:staff, :passed, :optional, :staff_active, :open_staff, :gym_staff),
      else: item(:staff, :failed, :optional, :no_active_staff, :open_staff, :gym_staff)
  end

  defp check(:members, gym, _now) do
    joined? = exists?(from(m in Member, where: m.gym_id == ^gym.id and m.status == :active))

    if joined?,
      do: item(:members, :passed, :optional, :members_active, :open_members, :gym_members),
      else: item(:members, :failed, :optional, :no_active_members, :open_members, :gym_members)
  end

  defp check(:member_products, gym, _now) do
    offered? =
      exists?(
        from(v in MemberProductVersion,
          join: p in MemberProduct,
          on: p.id == v.product_id,
          where: p.gym_id == ^gym.id and p.status == :active and v.status == :published
        )
      )

    if offered?,
      do:
        item(
          :member_products,
          :passed,
          :optional,
          :product_published,
          :open_memberships,
          :member_products
        ),
      else:
        item(
          :member_products,
          :failed,
          :optional,
          :no_published_product,
          :open_memberships,
          :member_products
        )
  end

  # Member payments stay unavailable until their decisions are approved
  # (SF-102 `Connect.member_payments/1`), whatever Stripe says about an
  # account; and they are not required to be listed.
  defp check(:member_payments, gym, _now) do
    {:unavailable, _reasons} = Connect.member_payments(gym.id)
    item(:member_payments, :blocked, :optional, :decisions_not_approved, nil, :payments)
  end

  defp check(:public_profile, _gym, _now),
    do:
      item(
        :public_profile,
        :unavailable,
        :future,
        :public_surface_not_available,
        nil,
        :publication
      )

  defp check(:community_settings, _gym, _now),
    do:
      item(
        :community_settings,
        :unavailable,
        :future,
        :community_features_not_available,
        nil,
        :community
      )

  defp item(key, status, requiredness, reason, action, source),
    do: %{
      key: key,
      status: status,
      requiredness: requiredness,
      reason_code: reason,
      action: action,
      source: source
    }

  defp exists?(query), do: Repo.exists?(query, @unlogged)

  defp now do
    %DateTime{microsecond: {us, _}} = at = Clock.utc_now()
    %{at | microsecond: {us, 6}}
  end
end
