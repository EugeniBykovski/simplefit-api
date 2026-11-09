defmodule SimpleFit.Sponsors.Provisioning do
  @moduledoc """
  The only way a sponsor organization or membership comes into being or changes
  (SF-112, ADR 0030). **Internal: no endpoint calls it.** Every function takes an
  `Authority`, which only this module hands out:

  * `application_authority/1` - for the Sponsor Application approval transaction
    (SF-116, ADR 0033). Given only inside a transaction, for an application that the
    same transaction has locked and approved and that has no organization yet;
    `provision_organization/3` runs with it *inside* the approval transaction, so an
    application is approved if and only if its organization and owner exist. The
    organization records `provisioning_source: sponsor_application` and the
    application id (unique: one organization per application).
  * `operator_authority/1` - for an operator's suspension or reinstatement of an
    approved application's organization (SF-116). Given only inside a transaction,
    for an operator the admin action pipeline has locked and authorized
    (`sponsors.restrict`); recorded as `platform_operator` with the operator's user.
  * `local_fixture_authority/0` - development and test builds only
    (`config :simple_fit, #{inspect(__MODULE__)}, local_fixture: true`); a
    production build refuses to compile with it. Recorded as `local_fixture`,
    which is never trust: it stands in for the approval only where no real
    sponsor can exist.

  Every change happens in one transaction with its organization history event
  (`sponsor_organization_events`), locks the organization row before its
  memberships, and is refused (`{:conflict, details}`) rather than silently
  repaired. Database constraints back each rule: one non-revoked membership per
  user and organization, at most one owner, exactly one active owner per
  organization that isn't closed (checked at commit), legal transitions only.

  Members only come from an explicit user id with completed account registration.
  Never from an email, a contact entry or an invitation link.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Repo
  alias SimpleFit.Sponsors.{Contact, Membership, Organization, OrganizationEvent}

  @local_fixture Application.compile_env(:simple_fit, [__MODULE__, :local_fixture], false)

  if Mix.env() == :prod and @local_fixture do
    raise "SF-112: a production build has no local sponsor provisioning authority (ADR 0030)"
  end

  defmodule Authority do
    @moduledoc "A provisioning authority. Only `SimpleFit.Sponsors.Provisioning` constructs one."
    @enforce_keys [:source]
    defstruct [:source, :application_id, :actor_user_id]

    @type t :: %__MODULE__{
            source: :sponsor_application | :local_fixture | :platform_operator,
            application_id: Ecto.UUID.t() | nil,
            actor_user_id: Ecto.UUID.t() | nil
          }
  end

  @reason ~r/^[a-z][a-z0-9_]{1,59}$/

  @type ctx :: %{optional(:request_id) => String.t() | nil}

  ## Authorities

  # One clause per build: `@local_fixture` is a compile-time constant.
  if @local_fixture do
    @doc "The local fixture authority, in builds that have one (never production)."
    @spec local_fixture_authority() :: {:ok, Authority.t()}
    def local_fixture_authority, do: {:ok, %Authority{source: :local_fixture}}
  else
    @doc "The local fixture authority: this build has none."
    @spec local_fixture_authority() :: {:error, :unavailable}
    def local_fixture_authority, do: {:error, :unavailable}
  end

  @doc """
  The authority of an approved sponsor application: only inside a transaction, for
  an application that is `approved` in it (locked `FOR UPDATE` here) and has no
  organization yet. `{:error, :unavailable}` otherwise.
  """
  @spec application_authority(Ecto.UUID.t()) :: {:ok, Authority.t()} | {:error, :unavailable}
  def application_authority(application_id) do
    with true <- Repo.in_transaction?(),
         {:ok, id} <- Ecto.UUID.cast(application_id),
         %{} <-
           Repo.one(
             from(a in SimpleFit.Sponsors.Application,
               where: a.id == ^id and a.status == :approved,
               lock: "FOR UPDATE"
             )
           ),
         false <-
           Repo.exists?(from(o in Organization, where: o.source_application_id == ^id)) do
      {:ok, %Authority{source: :sponsor_application, application_id: id}}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc """
  The authority of a platform operator acting through the admin action pipeline
  (which locked and authorized them): only inside a transaction.
  """
  @spec operator_authority(%{user_id: Ecto.UUID.t()}) ::
          {:ok, Authority.t()} | {:error, :unavailable}
  def operator_authority(%{user_id: user_id}) when is_binary(user_id) do
    if Repo.in_transaction?(),
      do: {:ok, %Authority{source: :platform_operator, actor_user_id: user_id}},
      else: {:error, :unavailable}
  end

  ## Organizations

  @doc """
  Provisions an approved organization with its owner and contacts, atomically.
  `attrs`: `provisioning_key` (uuid; a repeat with the same request returns the
  same organization, with another request `{:conflict, %{provisioning_key:
  "reused"}}`), `legal_name`, `display_name`, `country_code`, optional `website`,
  `owner_user_id` (an account with completed registration) and `contacts` (one
  `primary`, optional `additional`).
  """
  @spec provision_organization(Authority.t(), map(), ctx()) ::
          {:ok, %{organization: Organization.t(), owner: Membership.t()}}
          | {:error, Ecto.Changeset.t() | {:conflict, map()} | :unavailable}
  def provision_organization(%Authority{} = authority, attrs, ctx \\ %{}) do
    with {:ok, org_attrs, contacts} <- cast_organization(attrs) do
      Repo.transaction(fn -> provision!(authority, org_attrs, contacts, ctx) end)
    end
  end

  defp provision!(authority, attrs, contacts, ctx) do
    owner = eligible_user!(attrs.owner_user_id)

    org =
      %Organization{
        legal_name: attrs.legal_name,
        display_name: attrs.display_name,
        country_code: attrs.country_code,
        website: attrs[:website],
        status: :active,
        provisioning_source: authority.source,
        source_application_id: authority.application_id,
        provisioning_key: attrs.provisioning_key
      }
      |> Repo.insert!(on_conflict: :nothing, conflict_target: :provisioning_key)

    # With `on_conflict: :nothing` the struct keeps its client-side id; whether it was
    # stored is answered by the row that holds the key.
    stored_id =
      Repo.one(
        from(o in Organization,
          where: o.provisioning_key == ^attrs.provisioning_key,
          select: o.id
        )
      )

    if stored_id != org.id do
      repeated!(attrs, contacts)
    else
      membership = insert_membership!(org.id, owner.id, :owner)

      Enum.each(
        contacts,
        &Repo.insert!(struct(Contact, Map.put(&1, :organization_id, org.id)), log: false)
      )

      event!(org.id, "organization.provisioned", authority, ctx, to_state: "active")

      event!(org.id, "membership.added", authority, ctx,
        membership_id: membership.id,
        subject_user_id: owner.id,
        role: "owner",
        to_state: "active"
      )

      telemetry(:provisioned, authority)
      %{organization: Repo.reload!(org), owner: membership}
    end
  end

  # The same provisioning key again: the same request answers with what it made.
  defp repeated!(attrs, contacts) do
    org = Repo.one!(from(o in Organization, where: o.provisioning_key == ^attrs.provisioning_key))

    owner =
      Repo.one(from(m in Membership, where: m.organization_id == ^org.id and m.role == :owner))

    same =
      ((org.legal_name == attrs.legal_name and org.display_name == attrs.display_name and
          org.country_code == attrs.country_code and org.website == attrs[:website] and
          owner) && owner.user_id == attrs.owner_user_id) and
        length(contacts) ==
          Repo.aggregate(from(c in Contact, where: c.organization_id == ^org.id), :count)

    if same,
      do: %{organization: org, owner: owner},
      else: Repo.rollback({:conflict, %{provisioning_key: "reused"}})
  end

  @doc "Suspends an active organization: read-only for its members, no entry destination."
  @spec suspend_organization(Authority.t(), term(), String.t(), ctx()) :: result()
  def suspend_organization(authority, org_id, reason, ctx \\ %{}),
    do: organization_transition(authority, org_id, reason, ctx, :active, :suspended)

  @doc "Reinstates a suspended organization."
  @spec reinstate_organization(Authority.t(), term(), String.t(), ctx()) :: result()
  def reinstate_organization(authority, org_id, reason, ctx \\ %{}),
    do: organization_transition(authority, org_id, reason, ctx, :suspended, :active)

  @doc "Closes an organization for good: every membership is revoked (`organization_closed`)."
  @spec close_organization(Authority.t(), term(), String.t(), ctx()) :: result()
  def close_organization(authority, org_id, reason, ctx \\ %{}),
    do: organization_transition(authority, org_id, reason, ctx, [:active, :suspended], :closed)

  @type result :: {:ok, struct()} | {:error, :not_found | {:conflict, map()} | Ecto.Changeset.t()}

  defp organization_transition(%Authority{} = authority, org_id, reason, ctx, from, to) do
    with {:ok, id} <- uuid(org_id),
         :ok <- reason(reason) do
      Repo.transaction(fn -> change_organization!(authority, id, reason, ctx, {from, to}) end)
    end
  end

  defp change_organization!(authority, id, reason, ctx, {from, to}) do
    org = lock_organization!(id)

    unless org.status in List.wrap(from),
      do: Repo.rollback({:conflict, %{status: Atom.to_string(org.status)}})

    now = DateTime.utc_now()

    _revoked = if to == :closed, do: revoke_all!(org.id, authority, ctx, now)

    updated =
      org
      |> change(status: to)
      |> change(transition_stamp(to, now))
      |> Repo.update!()

    event!(org.id, "organization.#{to}", authority, ctx,
      from_state: Atom.to_string(org.status),
      to_state: Atom.to_string(to),
      reason_code: reason
    )

    telemetry(:organization_changed, authority)
    updated
  end

  defp transition_stamp(:suspended, now), do: [suspended_at: now]
  defp transition_stamp(:active, _now), do: [suspended_at: nil]
  defp transition_stamp(:closed, now), do: [closed_at: now]

  defp revoke_all!(org_id, authority, ctx, now) do
    memberships =
      Repo.all(
        from(m in Membership,
          where: m.organization_id == ^org_id and m.status != :revoked,
          order_by: m.id,
          lock: "FOR UPDATE"
        )
      )

    for m <- memberships do
      Repo.update!(
        change(m, status: :revoked, revoked_at: now, revoked_reason: "organization_closed")
      )

      event!(org_id, "membership.revoked", authority, ctx,
        membership_id: m.id,
        subject_user_id: m.user_id,
        role: Atom.to_string(m.role),
        from_state: Atom.to_string(m.status),
        to_state: "revoked",
        reason_code: "organization_closed"
      )
    end
  end

  ## Memberships

  @doc """
  Adds `user_id` (completed registration) to an active organization as `manager`
  or `member`. Never `owner`: an organization's owner comes only from provisioning
  (transfer awaits D-SA07). A user with a membership there already, suspended
  included, is a conflict.
  """
  @spec add_member(Authority.t(), term(), term(), :manager | :member, ctx()) ::
          {:ok, Membership.t()} | {:error, term()}
  def add_member(%Authority{} = authority, org_id, user_id, role, ctx \\ %{})
      when role in [:manager, :member] do
    with {:ok, org_id} <- uuid(org_id),
         {:ok, user_id} <- uuid(user_id) do
      Repo.transaction(fn -> add_member!(authority, org_id, user_id, role, ctx) end)
    end
  end

  defp add_member!(authority, org_id, user_id, role, ctx) do
    org = lock_organization!(org_id)

    if org.status != :active,
      do: Repo.rollback({:conflict, %{status: Atom.to_string(org.status)}})

    user = eligible_user!(user_id)
    membership = insert_membership!(org.id, user.id, role)

    event!(org.id, "membership.added", authority, ctx,
      membership_id: membership.id,
      subject_user_id: user.id,
      role: Atom.to_string(role),
      to_state: "active"
    )

    telemetry(:membership_changed, authority)
    membership
  end

  @doc "Suspends an active membership (not the owner's): it gives no access until reinstated."
  @spec suspend_membership(Authority.t(), term(), String.t(), ctx()) :: result()
  def suspend_membership(authority, membership_id, reason, ctx \\ %{}),
    do: membership_transition(authority, membership_id, reason, ctx, :active, :suspended)

  @doc "Reinstates a suspended membership."
  @spec reinstate_membership(Authority.t(), term(), String.t(), ctx()) :: result()
  def reinstate_membership(authority, membership_id, reason, ctx \\ %{}),
    do: membership_transition(authority, membership_id, reason, ctx, :suspended, :active)

  @doc "Revokes a membership for good (not the owner's). The next request is `:not_found`."
  @spec revoke_membership(Authority.t(), term(), String.t(), ctx()) :: result()
  def revoke_membership(authority, membership_id, reason, ctx \\ %{}),
    do:
      membership_transition(
        authority,
        membership_id,
        reason,
        ctx,
        [:active, :suspended],
        :revoked
      )

  defp membership_transition(%Authority{} = authority, membership_id, reason, ctx, from, to) do
    with {:ok, id} <- uuid(membership_id),
         :ok <- reason(reason),
         %Membership{organization_id: org_id} <- Repo.get(Membership, id) do
      Repo.transaction(fn ->
        change_membership!(authority, {org_id, id}, reason, ctx, {from, to})
      end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp change_membership!(authority, {org_id, id}, reason, ctx, {from, to}) do
    org = lock_organization!(org_id)
    m = Repo.one!(from(x in Membership, where: x.id == ^id, lock: "FOR UPDATE"))

    transitionable!(org, m, from)

    now = DateTime.utc_now()
    updated = Repo.update!(change(m, membership_changes(to, reason, now)))

    event!(org.id, "membership.#{to}", authority, ctx,
      membership_id: m.id,
      subject_user_id: m.user_id,
      role: Atom.to_string(m.role),
      from_state: Atom.to_string(m.status),
      to_state: Atom.to_string(to),
      reason_code: reason
    )

    telemetry(:membership_changed, authority)
    updated
  end

  # The owner stays until transfer exists (D-SA07); a closed organization is final.
  defp transitionable!(org, m, from) do
    cond do
      org.status == :closed ->
        Repo.rollback({:conflict, %{status: "closed"}})

      m.role == :owner ->
        Repo.rollback({:conflict, %{membership: "owner"}})

      m.status not in List.wrap(from) ->
        Repo.rollback({:conflict, %{membership: Atom.to_string(m.status)}})

      true ->
        :ok
    end
  end

  defp membership_changes(:suspended, _reason, now), do: [status: :suspended, suspended_at: now]
  defp membership_changes(:active, _reason, _now), do: [status: :active, suspended_at: nil]

  defp membership_changes(:revoked, reason, now),
    do: [status: :revoked, revoked_at: now, revoked_reason: reason]

  ## Shared

  defp insert_membership!(org_id, user_id, role) do
    %Membership{organization_id: org_id, user_id: user_id, role: role, status: :active}
    |> change()
    |> unique_constraint([:organization_id, :user_id],
      name: :sponsor_workspace_memberships_one_per_user_index
    )
    |> unique_constraint(:organization_id, name: :sponsor_workspace_memberships_one_owner_index)
    |> Repo.insert()
    |> case do
      {:ok, membership} -> membership
      {:error, _} -> Repo.rollback({:conflict, %{membership: "exists"}})
    end
  end

  defp eligible_user!(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user ->
        if Accounts.registration_complete?(user),
          do: user,
          else: Repo.rollback({:conflict, %{user: "not_eligible"}})

      nil ->
        Repo.rollback({:conflict, %{user: "not_eligible"}})
    end
  end

  defp lock_organization!(id) do
    Repo.one(from(o in Organization, where: o.id == ^id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp event!(org_id, event, authority, ctx, fields) do
    Repo.insert!(
      struct(
        OrganizationEvent,
        Map.merge(
          %{
            organization_id: org_id,
            occurred_at: DateTime.utc_now(),
            event: event,
            authority: authority.source,
            actor_user_id: authority.actor_user_id,
            request_id: request_id(Map.get(ctx, :request_id))
          },
          Map.new(fields)
        )
      )
    )
  end

  defp request_id(id) when is_binary(id) and byte_size(id) <= 200, do: id
  defp request_id(_id), do: nil

  defp telemetry(event, authority),
    do:
      :telemetry.execute([:simple_fit, :sponsors, event], %{count: 1}, %{
        authority: authority.source
      })

  defp reason(reason) when is_binary(reason) do
    if reason =~ @reason, do: :ok, else: invalid(:reason_code)
  end

  defp reason(_reason), do: invalid(:reason_code)

  defp invalid(field),
    do:
      {:error,
       {%{}, %{field => :string}}
       |> change()
       |> add_error(field, "is invalid", validation: :format)}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  ## Input

  defp cast_organization(attrs) do
    types = %{
      provisioning_key: Ecto.UUID,
      legal_name: :string,
      display_name: :string,
      country_code: :string,
      website: :string,
      owner_user_id: Ecto.UUID
    }

    required = [:provisioning_key, :legal_name, :display_name, :country_code, :owner_user_id]

    changeset =
      {%{}, types}
      |> cast(attrs, Map.keys(types))
      |> update_change(:legal_name, &String.trim/1)
      |> update_change(:display_name, &String.trim/1)
      |> update_change(:country_code, &String.upcase/1)
      |> validate_required(required)
      |> validate_length(:legal_name, min: 1, max: 200)
      |> validate_length(:display_name, min: 1, max: 120)
      |> validate_format(:country_code, ~r/^[A-Z]{2}$/)
      |> validate_format(:website, ~r/^https:\/\/\S+$/)
      |> validate_length(:website, max: 200)

    contacts = Enum.map(List.wrap(attrs[:contacts] || attrs["contacts"]), &cast_contact/1)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      Enum.any?(contacts, &match?({:error, _}, &1)) ->
        Enum.find(contacts, &match?({:error, _}, &1))

      Enum.count(contacts, fn {:ok, c} -> c.kind == :primary end) != 1 ->
        {:error,
         add_error(changeset, :contacts, "needs exactly one primary contact", validation: :length)}

      true ->
        {:ok, apply_changes(changeset), Enum.map(contacts, fn {:ok, c} -> c end)}
    end
  end

  defp cast_contact(attrs) do
    types = %{
      kind: :string,
      full_name: :string,
      job_title: :string,
      email: :string,
      phone: :string
    }

    {%{}, types}
    |> cast(attrs, Map.keys(types))
    |> update_change(:full_name, &String.trim/1)
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:kind, :full_name, :email])
    |> validate_inclusion(:kind, ["primary", "additional"])
    |> validate_length(:full_name, min: 1, max: 120)
    |> validate_length(:job_title, min: 1, max: 120)
    |> validate_length(:email, min: 3, max: 254)
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+$/)
    |> validate_format(:phone, ~r/^\+[1-9][0-9]{6,14}$/)
    |> apply_action(:validate)
    |> case do
      {:ok, c} -> {:ok, %{c | kind: String.to_existing_atom(c.kind)}}
      error -> error
    end
  end
end
