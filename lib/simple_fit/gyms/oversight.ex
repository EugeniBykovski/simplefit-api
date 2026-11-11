defmodule SimpleFit.Gyms.Oversight do
  @moduledoc """
  Platform operator oversight of gyms (SF-123): read-only projections owned by the
  Gyms context, reached only through `SimpleFit.Operators` (`gyms.read`).

  What a gym shows here is its own state, never its people's data:

  * **List** - name, type, lifecycle (`setup_status`), the current business
    verification status, the primary location's country and city, the active staff
    count and when it was created. Filters: a case-insensitive name prefix,
    lifecycle, verification status and country; newest first, keyset pages.
  * **One gym** - the same, its revision, the owner's user id, active staff counts by
    role, pending staff invitations, member counts by status (counts only) and the
    verification application's status, revision and dates. Never the application's
    declared business details, its documents, member names or contact details.

  The gym has no suspension, closure or publication state (ADR 0026, D-G09–D-G11),
  so none is reported; verification is the SF-103 application's status, or
  `:not_started`.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Gyms.{
    Gym,
    GymLocation,
    Member,
    StaffInvitation,
    StaffMembership,
    VerificationApplication
  }

  alias SimpleFit.Repo

  @unlogged [log: false]

  @current [:draft, :submitted, :changes_requested, :approved]

  @typedoc "A list filter: name prefix, lifecycle, verification status or country."
  @type filters :: %{
          optional(:name_prefix) => String.t(),
          optional(:lifecycle) => Gym.setup_status(),
          optional(:verification) => :not_started | VerificationApplication.status(),
          optional(:country) => String.t()
        }

  @doc "The verification statuses a list can be filtered by."
  @spec verification_statuses() :: [atom()]
  def verification_statuses,
    do: [:not_started | Ecto.Enum.values(VerificationApplication, :status)]

  @doc """
  One page of gyms, newest first: `{rows, next}` where `next` is the position
  `{inserted_at, id}` after the last row, or `nil` on the last page.
  """
  @spec page(filters(), pos_integer(), {DateTime.t(), Ecto.UUID.t()} | nil) ::
          {[map()], {DateTime.t(), Ecto.UUID.t()} | nil}
  def page(filters, limit, position) do
    rows =
      base_query()
      |> filter(filters)
      |> after_position(position)
      |> then(
        &from([gym: g] in &1, order_by: [desc: g.inserted_at, desc: g.id], limit: ^(limit + 1))
      )
      |> Repo.all(@unlogged)
      |> Enum.map(&not_started/1)

    {page, more} = Enum.split(rows, limit)
    staff = active_staff(Enum.map(page, & &1.id))

    next =
      case {page, more} do
        {_, []} -> nil
        {page, _} -> {List.last(page).created_at, List.last(page).id}
      end

    {Enum.map(page, &Map.put(&1, :staff_count, Map.get(staff, &1.id, 0))), next}
  end

  @doc """
  One gym's operator view, or `nil`. Callers wanting the parts to describe one
  instant run it in a read-only snapshot (`SimpleFit.Operators.Overview.snapshot/1`).
  """
  @spec view(Ecto.UUID.t()) :: map() | nil
  def view(gym_id) do
    case Repo.one(from([gym: g] in base_query(), where: g.id == ^gym_id), @unlogged) do
      nil ->
        nil

      gym ->
        now = DateTime.utc_now()

        gym
        |> not_started()
        |> Map.merge(%{
          owner_user_id: owner(gym_id),
          staff: staff_by_role(gym_id),
          staff_invitations_pending: pending_invitations(gym_id, now),
          members: members_by_status(gym_id),
          verification: verification(gym_id)
        })
    end
  end

  # The gym, its primary active location and its current verification status, as the
  # list and the detail both show them.
  defp base_query do
    latest =
      from(a in VerificationApplication,
        where: a.gym_id == parent_as(:gym).id,
        order_by: [desc: a.status in ^@current, desc: a.inserted_at, desc: a.id],
        limit: 1,
        select: %{status: a.status}
      )

    from(g in Gym,
      as: :gym,
      left_join: l in GymLocation,
      as: :location,
      on: l.gym_id == g.id and l.is_primary and is_nil(l.archived_at),
      left_lateral_join: v in subquery(latest),
      as: :verification,
      on: true,
      select: %{
        id: g.id,
        name: g.name,
        gym_type: g.gym_type,
        lifecycle: g.setup_status,
        revision: g.revision,
        verification_status: v.status,
        country_code: l.country_code,
        city: l.city,
        created_at: g.inserted_at
      }
    )
  end

  defp not_started(%{verification_status: nil} = row),
    do: %{row | verification_status: :not_started}

  defp not_started(row), do: row

  defp filter(query, filters) do
    Enum.reduce(filters, query, fn
      {:name_prefix, prefix}, q ->
        pattern = escape_like(String.downcase(prefix)) <> "%"
        from([gym: g] in q, where: fragment("lower(?) LIKE ? ESCAPE '\\'", g.name, ^pattern))

      {:lifecycle, lifecycle}, q ->
        from([gym: g] in q, where: g.setup_status == ^lifecycle)

      {:verification, :not_started}, q ->
        from([verification: v] in q, where: is_nil(v.status))

      {:verification, status}, q ->
        from([verification: v] in q, where: v.status == ^status)

      {:country, country}, q ->
        from([location: l] in q, where: l.country_code == ^country)
    end)
  end

  defp escape_like(value), do: String.replace(value, ~r/[\\%_]/, "\\\\\\0")

  defp after_position(query, nil), do: query

  defp after_position(query, {at, id}),
    do:
      from([gym: g] in query,
        where: g.inserted_at < ^at or (g.inserted_at == ^at and g.id < ^id)
      )

  defp active_staff([]), do: %{}

  defp active_staff(ids) do
    from(s in StaffMembership,
      where: s.gym_id in ^ids and s.status == :active,
      group_by: s.gym_id,
      select: {s.gym_id, count()}
    )
    |> Repo.all(@unlogged)
    |> Map.new()
  end

  defp owner(gym_id) do
    Repo.one(
      from(s in StaffMembership,
        where: s.gym_id == ^gym_id and s.role == :owner and s.status == :active,
        select: s.user_id
      ),
      @unlogged
    )
  end

  defp staff_by_role(gym_id) do
    counts =
      from(s in StaffMembership,
        where: s.gym_id == ^gym_id and s.status == :active and s.role != :owner,
        group_by: s.role,
        select: {s.role, count()}
      )
      |> Repo.all(@unlogged)
      |> Map.new()

    Map.new([:manager, :coach, :front_desk], &{&1, Map.get(counts, &1, 0)})
  end

  # Pending and not yet expired: what `StaffInvitation.effective_status/2` calls pending.
  defp pending_invitations(gym_id, now) do
    Repo.aggregate(
      from(i in StaffInvitation,
        where: i.gym_id == ^gym_id and i.status == :pending and i.expires_at > ^now
      ),
      :count,
      @unlogged
    )
  end

  defp members_by_status(gym_id) do
    counts =
      from(m in Member,
        where: m.gym_id == ^gym_id and m.status in [:active, :requested],
        group_by: m.status,
        select: {m.status, count()}
      )
      |> Repo.all(@unlogged)
      |> Map.new()

    %{active: Map.get(counts, :active, 0), requested: Map.get(counts, :requested, 0)}
  end

  defp verification(gym_id) do
    Repo.one(
      from(a in VerificationApplication,
        where: a.gym_id == ^gym_id,
        order_by: [desc: a.status in ^@current, desc: a.inserted_at, desc: a.id],
        limit: 1,
        select: %{
          status: a.status,
          revision: a.revision,
          submitted_at: a.submitted_at,
          decided_at: a.decided_at
        }
      ),
      @unlogged
    ) || %{status: :not_started, revision: nil, submitted_at: nil, decided_at: nil}
  end
end
