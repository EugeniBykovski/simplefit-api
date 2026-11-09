defmodule SimpleFit.Sponsors do
  @moduledoc """
  Sponsor organizations and their workspace memberships (SF-112, ADR 0030; the
  operator-free half of the proposed ADR 0027).

  **Authorization.** Every organization operation names the organization and is
  authorized against the viewer's own **active** membership of it, read on every
  call with no cache, in an organization that isn't closed (a suspended one is
  read-only). Anyone else (no membership, a suspended or revoked one, another
  organization, a closed organization, an operator, a gym owner, an applicant)
  gets `:not_found`, so an organization's existence is never revealed. A member
  whose role lacks the permission (`SimpleFit.Sponsors.Policy`) gets `:forbidden`.

  **What this context doesn't do.** Organizations and memberships are created and
  changed only by `SimpleFit.Sponsors.Provisioning` (no public endpoint, disabled in
  production until the Sponsor Application approval exists). There are no
  invitations, ownership transfer, role changes, member removal or brand edits yet:
  their decisions (D-SA07, D-SA08, D-SA12) are open. Registration intent `sponsor`
  creates nothing (`SimpleFit.Entry`).

  Telemetry `[:simple_fit, :sponsors, :access_denied]` counts refusals by reason,
  never with an organization or user id.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Repo
  alias SimpleFit.Sponsors.{Contact, Membership, Organization, Policy}

  @default_limit 50
  @max_limit 100

  @type workspace_summary :: %{
          sponsor_id: Ecto.UUID.t(),
          display_name: String.t(),
          role: Membership.role(),
          organization_status: Organization.status()
        }

  @type access :: %{organization: Organization.t(), membership: Membership.t()}

  ## The viewer's organizations

  @doc """
  The viewer's sponsor organizations: active memberships of organizations that
  aren't closed, oldest membership first. Suspended and revoked memberships are
  absent (they give no access).
  """
  @spec list_my_organizations(User.t()) :: [access()]
  def list_my_organizations(%User{id: user_id}) do
    Repo.all(
      from(m in Membership,
        join: o in Organization,
        on: o.id == m.organization_id,
        where: m.user_id == ^user_id and m.status == :active and o.status != :closed,
        order_by: [asc: m.inserted_at, asc: m.id],
        select: %{organization: o, membership: m}
      )
    )
  end

  @doc """
  The viewer's sponsor workspaces for entry resolution (ADR 0017, SF-112): active
  memberships of **active** organizations only (a suspended organization isn't an
  entry destination), at most `limit` summaries, oldest first, plus the total.
  """
  @spec workspace_overview(User.t(), pos_integer()) :: %{
          total: non_neg_integer(),
          single_sponsor_id: Ecto.UUID.t() | nil,
          entries: [workspace_summary()]
        }
  def workspace_overview(%User{} = user, limit) do
    query = workspaces_query(user.id)
    total = Repo.aggregate(query, :count)
    entries = Repo.all(from([m, o] in query, limit: ^limit, select: {o, m}))

    %{
      total: total,
      single_sponsor_id: if(total == 1, do: entries |> hd() |> elem(0) |> Map.fetch!(:id)),
      entries: Enum.map(entries, fn {o, m} -> summary(o, m) end)
    }
  end

  @doc "The viewer's workspace `sponsor_id` when it's an entry destination for them, else `:not_found`."
  @spec workspace(User.t(), term()) :: {:ok, workspace_summary()} | {:error, :not_found}
  def workspace(%User{} = user, sponsor_id), do: one_workspace(user, sponsor_id, false)

  @doc """
  As `workspace/2`, inside a transaction, share-locking the organization and the
  membership: a concurrent revocation or suspension commits before (then
  `:not_found`) or after the caller's write.
  """
  @spec lock_workspace(User.t(), term()) :: {:ok, workspace_summary()} | {:error, :not_found}
  def lock_workspace(%User{} = user, sponsor_id), do: one_workspace(user, sponsor_id, true)

  defp one_workspace(user, sponsor_id, false) do
    with {:ok, id} <- uuid(sponsor_id) do
      case Repo.one(from([m, o] in workspaces_query(user.id), where: o.id == ^id, select: {o, m})) do
        {o, m} -> {:ok, summary(o, m)}
        nil -> {:error, :not_found}
      end
    end
  end

  # The organization first, then the membership: the order `Sponsors.Provisioning`
  # takes them in, so a choice and a revocation never deadlock (SF-113 fix: one
  # joined `FOR SHARE` query locked the two rows in no fixed order).
  defp one_workspace(user, sponsor_id, true) do
    with {:ok, id} <- uuid(sponsor_id),
         %Organization{status: :active} = o <-
           Repo.one(from(o in Organization, where: o.id == ^id, lock: "FOR SHARE")),
         %Membership{} = m <-
           Repo.one(
             from(m in Membership,
               where: m.organization_id == ^id and m.user_id == ^user.id and m.status == :active,
               lock: "FOR SHARE"
             )
           ) do
      {:ok, summary(o, m)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp workspaces_query(user_id) do
    from(m in Membership,
      join: o in Organization,
      on: o.id == m.organization_id,
      where: m.user_id == ^user_id and m.status == :active and o.status == :active,
      order_by: [asc: m.inserted_at, asc: m.id]
    )
  end

  defp summary(organization, membership) do
    %{
      sponsor_id: organization.id,
      display_name: organization.display_name,
      role: membership.role,
      organization_status: organization.status
    }
  end

  ## One organization (authorized by the viewer's membership)

  @doc "The organization, the viewer's membership and its permissions (`view_organization`)."
  @spec get_organization(User.t(), term()) ::
          {:ok, map()} | {:error, :not_found | :forbidden}
  def get_organization(%User{} = user, sponsor_id) do
    with {:ok, access} <- authorize(user, sponsor_id, :view_organization) do
      {:ok, Map.put(access, :permissions, Policy.for_role(access.membership.role))}
    end
  end

  @doc """
  The organization's current members (active and suspended), oldest first, paged
  (`limit` 1..100, default 50; `cursor`) (`view_members`). Names are the short
  account names (`SimpleFit.Accounts.short_names/1`): never an email.
  """
  @spec list_members(User.t(), term(), map()) ::
          {:ok, %{entries: [map()], next_cursor: String.t() | nil}}
          | {:error, :not_found | :forbidden | Changeset.t()}
  def list_members(%User{} = user, sponsor_id, params \\ %{}) do
    with {:ok, access} <- authorize(user, sponsor_id, :view_members),
         {:ok, %{limit: limit, cursor: cursor}} <- paging(params) do
      org_id = access.organization.id

      rows =
        from(m in Membership,
          where: m.organization_id == ^org_id and m.status != :revoked,
          order_by: [asc: m.inserted_at, asc: m.id],
          limit: ^(limit + 1)
        )
        |> after_cursor(cursor)
        |> Repo.all()

      {page, rest} = Enum.split(rows, limit)
      names = Accounts.short_names(Enum.map(page, & &1.user_id))

      {:ok,
       %{
         entries: Enum.map(page, &member(&1, names, user.id)),
         next_cursor: if(rest != [], do: encode_cursor(List.last(page)))
       }}
    end
  end

  defp member(membership, names, viewer_id) do
    %{
      membership_id: membership.id,
      short_name: get_in(names, [membership.user_id, :short_name]),
      role: membership.role,
      status: membership.status,
      joined_at: membership.inserted_at,
      is_viewer: membership.user_id == viewer_id
    }
  end

  @doc "The organization's business contacts (`view_contacts`: owner and manager)."
  @spec list_contacts(User.t(), term()) ::
          {:ok, [Contact.t()]} | {:error, :not_found | :forbidden}
  def list_contacts(%User{} = user, sponsor_id) do
    with {:ok, access} <- authorize(user, sponsor_id, :view_contacts) do
      org_id = access.organization.id

      {:ok,
       Repo.all(
         from(c in Contact,
           where: c.organization_id == ^org_id,
           order_by: [desc: c.kind == :primary, asc: c.inserted_at, asc: c.id]
         )
       )}
    end
  end

  @doc """
  The viewer's access to `sponsor_id` for `permission`: an active membership of
  that organization while it isn't closed. `:not_found` for anyone else (existence
  is never revealed); `:forbidden` for a member whose role lacks the permission.
  """
  @spec authorize(User.t(), term(), Policy.permission()) ::
          {:ok, access()} | {:error, :not_found | :forbidden}
  def authorize(%User{id: user_id}, sponsor_id, permission) do
    with {:ok, id} <- uuid(sponsor_id),
         %{membership: membership} = access <-
           Repo.one(
             from(m in Membership,
               join: o in Organization,
               on: o.id == m.organization_id,
               where:
                 m.organization_id == ^id and m.user_id == ^user_id and m.status == :active and
                   o.status != :closed,
               select: %{organization: o, membership: m}
             )
           ) do
      if Policy.allowed?(membership.role, permission),
        do: {:ok, access},
        else: denied(:forbidden)
    else
      _ -> denied(:not_found)
    end
  end

  defp denied(reason) do
    :telemetry.execute([:simple_fit, :sponsors, :access_denied], %{count: 1}, %{reason: reason})
    {:error, reason}
  end

  ## Paging (keyset on `(inserted_at, id)`, as the gym lists)

  defp paging(params) do
    types = %{limit: :integer, cursor: :string}

    changeset =
      {%{limit: @default_limit, cursor: nil}, types}
      |> Changeset.cast(Map.take(params, ["limit", "cursor"]), Map.keys(types))
      |> Changeset.validate_number(:limit,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: @max_limit
      )

    with %Changeset{valid?: true} <- changeset,
         {:ok, position} <- decode_cursor(Changeset.get_field(changeset, :cursor)) do
      {:ok, %{limit: Changeset.get_field(changeset, :limit), cursor: position}}
    else
      %Changeset{} = invalid ->
        {:error, invalid}

      :error ->
        {:error, Changeset.add_error(changeset, :cursor, "is invalid", validation: :format)}
    end
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {at, id}),
    do: from(m in query, where: m.inserted_at > ^at or (m.inserted_at == ^at and m.id > ^id))

  defp encode_cursor(%Membership{inserted_at: at, id: id}),
    do: Base.url_encode64("#{DateTime.to_unix(at, :microsecond)}|#{id}", padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [micros, id] <- String.split(decoded, "|"),
         {micros, ""} <- Integer.parse(micros),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :error
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
