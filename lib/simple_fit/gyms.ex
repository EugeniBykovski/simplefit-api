defmodule SimpleFit.Gyms do
  @moduledoc """
  Gyms: the tenant, its staff (workspace) memberships and their permissions
  (ADR 0026; SF-83).

  A gym is the tenant root of everything gym-scoped. People work at a gym
  through a staff membership with one fixed role (`owner`, `manager`,
  `coach`, `front_desk`); a user may hold memberships at several gyms, each
  with its own role, and nothing about a gym is stored on the user (no role,
  type or "current gym"; ADR 0009). Exactly one active owner per gym is a
  database invariant (D-G04).

  ## Authorization (D-G15, D-G24)

  Every gym operation names the gym explicitly (the API path
  `/api/v1/gyms/{gym_id}/...`) and acts for the authenticated user. Access is
  re-derived on every call from that user's active staff membership at that
  gym and the fixed matrix in `SimpleFit.Gyms.Policy`:

    * unknown gym, malformed id, or no active membership there -> `:not_found`
      (outsiders never learn that a private gym exists);
    * active membership whose role lacks the permission -> `:forbidden`.

  Nothing else grants gym rights: not an account, a Coach or Fighter profile,
  a Coach–Fighter relationship, or a client-selected workspace. No gym
  permission reads a fighter's private training data (D-G06).

  ## Boundaries

  Creating a gym creates a draft and its owner membership only (D-G05). The
  setup steps, locations and completion (which requires a primary location)
  are SF-85's; entry projection (`GYM_WORKSPACE`) is SF-84's; staff roles,
  coach affiliation and invitations are SF-93's (`SimpleFit.Gyms.Staff`,
  `SimpleFit.Gyms.StaffInvitations`); gym members (participants), their
  enrollment, member invitations and the member-list dry run are SF-95's
  (`SimpleFit.Gyms.Members`, `SimpleFit.Gyms.MemberInvitations`,
  `SimpleFit.Gyms.MemberImport`). Ownership transfer exists here as a domain operation only: the
  transfer request and acceptance (D-G04) need a dedicated backend ticket.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.User

  alias SimpleFit.Gyms.{
    Access,
    Audit,
    Bookings,
    ClassTemplates,
    Commerce,
    Creation,
    FirstRun,
    GoLive,
    Guarded,
    Gym,
    GymLocation,
    MemberImport,
    MemberInvitations,
    Members,
    Ownership,
    Policy,
    Setup,
    Staff,
    StaffInvitations,
    StaffMembership,
    Timetable,
    Venues,
    Verification,
    VerificationEvidence
  }

  alias SimpleFit.Accounts.Session

  alias SimpleFit.Repo

  @default_limit 50
  @max_limit 100

  @typedoc "A gym as one of its staff sees it, with that viewer's role and permissions."
  @type view :: map()

  @typedoc "A page of views and the cursor of the next one (`nil` on the last page)."
  @type page :: %{entries: [view()], next_cursor: String.t() | nil}

  ## Creation

  @doc """
  Creates a draft gym owned by `user` and its owner membership, atomically
  (`attrs`, string keys: `client_request_id`, `name`, `gym_type`; nothing
  else; the user's account registration must be complete). A replayed
  `client_request_id` returns the same gym (`:existing`); while the user has
  an open draft, any create returns it (`:resumed`). See
  `SimpleFit.Gyms.Creation` for idempotency, locking and abuse limits.
  """
  @spec create_gym(User.t(), map(), String.t()) ::
          {:ok, view(), Creation.outcome()}
          | {:error, Changeset.t() | {:conflict, map()} | {:rate_limited, pos_integer()}}
  def create_gym(%User{} = user, attrs, client_ip) do
    with {:ok, gym, membership, outcome} <- Creation.create(user, attrs, client_ip) do
      {:ok, view(gym, membership, locations(gym.id)), outcome}
    end
  end

  ## Setup (SF-85)

  @typedoc "A gym's setup as one of its staff sees it, with readiness."
  @type setup_view :: map()

  @doc "The setup of a gym for one of its active staff (`:not_found` otherwise)."
  @spec get_setup(User.t(), term()) :: {:ok, setup_view()} | {:error, :not_found}
  def get_setup(%User{} = user, gym_id) do
    with {:ok, state} <- Setup.get(user, gym_id), do: {:ok, setup_view(state)}
  end

  @doc "A partial setup update (see `SimpleFit.Gyms.Setup.update/3`)."
  @spec update_setup(User.t(), term(), map()) :: {:ok, setup_view()} | {:error, Setup.error()}
  def update_setup(%User{} = user, gym_id, attrs) do
    with {:ok, state} <- Setup.update(user, gym_id, attrs), do: {:ok, setup_view(state)}
  end

  @doc "Sets or replaces the primary location (see `SimpleFit.Gyms.Setup.put_primary_location/3`)."
  @spec put_primary_location(User.t(), term(), map()) ::
          {:ok, setup_view()} | {:error, Setup.error()}
  def put_primary_location(%User{} = user, gym_id, attrs) do
    with {:ok, state} <- Setup.put_primary_location(user, gym_id, attrs),
         do: {:ok, setup_view(state)}
  end

  @doc "Completes a draft's setup, owner only (see `SimpleFit.Gyms.Setup.complete/2`)."
  @spec complete_setup(User.t(), term()) ::
          {:ok, setup_view(), :completed | :already_completed} | {:error, Setup.error()}
  def complete_setup(%User{} = user, gym_id) do
    with {:ok, state, outcome} <- Setup.complete(user, gym_id),
         do: {:ok, setup_view(state), outcome}
  end

  @doc "Discards a draft, owner only (see `SimpleFit.Gyms.Setup.discard/2`)."
  @spec discard_draft(User.t(), term()) ::
          :ok | {:error, :not_found | :forbidden | {:conflict, map()}}
  defdelegate discard_draft(user, gym_id), to: Setup, as: :discard

  ## First run (SF-90)

  @doc """
  The owner's first run at a completed gym and the gym's setup checklist
  (see `SimpleFit.Gyms.FirstRun`): `:not_found` for anyone without an active
  membership there, `:forbidden` for staff other than the owner.
  """
  @spec get_first_run(User.t(), term()) ::
          {:ok, FirstRun.state()} | {:error, :not_found | :forbidden}
  defdelegate get_first_run(user, gym_id), to: FirstRun, as: :get

  @doc """
  An explicit first-run transition, `:start`, `:complete` or `:dismiss`
  (`attrs`: the request body, which must be empty). See
  `SimpleFit.Gyms.FirstRun.transition/4`.
  """
  @spec first_run_transition(User.t(), term(), FirstRun.action(), map()) ::
          {:ok, FirstRun.state()} | {:error, FirstRun.error()}
  defdelegate first_run_transition(user, gym_id, action, attrs), to: FirstRun, as: :transition

  ## Business verification and go-live (SF-103)

  @doc """
  The gym's business verification, for its owner (`:not_found` without an
  active membership, `:forbidden` for other staff). See
  `SimpleFit.Gyms.Verification`.
  """
  @spec get_business_verification(User.t(), term()) ::
          {:ok, Verification.view()} | {:error, :not_found | :forbidden}
  defdelegate get_business_verification(user, gym_id), to: Verification, as: :get

  @doc "Creates or changes the owner's draft application. See `SimpleFit.Gyms.Verification.save/4`."
  @spec save_business_verification(User.t(), Session.t(), term(), map()) ::
          {:ok, {Verification.view(), :created | :updated}} | {:error, Verification.error()}
  defdelegate save_business_verification(user, session, gym_id, attrs),
    to: Verification,
    as: :save

  @doc "Submits the application for review. See `SimpleFit.Gyms.Verification.submit/4`."
  @spec submit_business_verification(User.t(), Session.t(), term(), map()) ::
          {:ok, Verification.view()} | {:error, Verification.error()}
  defdelegate submit_business_verification(user, session, gym_id, attrs),
    to: Verification,
    as: :submit

  @doc "Announces a document and presigns its upload. See `SimpleFit.Gyms.Verification.add_evidence/4`."
  @spec add_business_verification_evidence(User.t(), Session.t(), term(), map()) ::
          {:ok, {Verification.view(), VerificationEvidence.t(), SimpleFit.Storage.Presigned.t()}}
          | {:error, Verification.error()}
  defdelegate add_business_verification_evidence(user, session, gym_id, attrs),
    to: Verification,
    as: :add_evidence

  @doc "Attaches an uploaded document. See `SimpleFit.Gyms.Verification.confirm_evidence/4`."
  @spec confirm_business_verification_evidence(User.t(), Session.t(), term(), term()) ::
          {:ok, Verification.view()} | {:error, Verification.error()}
  defdelegate confirm_business_verification_evidence(user, session, gym_id, evidence_id),
    to: Verification,
    as: :confirm_evidence

  @doc "Removes an unsubmitted document. See `SimpleFit.Gyms.Verification.remove_evidence/5`."
  @spec remove_business_verification_evidence(User.t(), Session.t(), term(), term(), map()) ::
          {:ok, Verification.view()} | {:error, Verification.error()}
  defdelegate remove_business_verification_evidence(user, session, gym_id, evidence_id, attrs),
    to: Verification,
    as: :remove_evidence

  @doc """
  The gym's go-live readiness, for its owner and managers. See
  `SimpleFit.Gyms.GoLive`.
  """
  @spec get_go_live(User.t(), term()) ::
          {:ok, GoLive.readiness()} | {:error, :not_found | :forbidden}
  defdelegate get_go_live(user, gym_id), to: GoLive, as: :get

  defp setup_view(%{gym: gym, membership: membership, primary_location: location}) do
    %{
      gym_id: gym.id,
      setup_status: gym.setup_status,
      revision: gym.revision,
      name: gym.name,
      gym_type: gym.gym_type,
      phone: gym.phone,
      website: gym.website,
      tagline: gym.tagline,
      accent_color: gym.accent_color,
      primary_location: location && location_view(location),
      missing_requirements:
        if(gym.setup_status == :draft, do: Setup.missing_requirements(gym, location), else: []),
      viewer: %{
        staff_membership_id: membership.id,
        role: membership.role,
        permissions: Policy.permissions_of(membership.role)
      }
    }
  end

  ## Reads

  @doc """
  The gyms where `user` holds an active staff membership, newest membership
  first (params: `limit` 1..100, default 50; `cursor` from the previous page).
  Only the user's own memberships are read.
  """
  @spec list_my_gyms(User.t(), map()) :: {:ok, page()} | {:error, Changeset.t()}
  def list_my_gyms(%User{id: user_id}, params) when is_binary(user_id) and is_map(params) do
    with {:ok, %{limit: limit, cursor: cursor}} <- page_params(params) do
      rows =
        from(m in StaffMembership,
          join: g in Gym,
          on: g.id == m.gym_id,
          where: m.user_id == ^user_id and m.status == :active,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^(limit + 1),
          select: {g, m}
        )
        |> seek(cursor)
        |> Repo.all(log: false)

      {rows, rest} = Enum.split(rows, limit)

      {:ok,
       %{
         entries: Enum.map(rows, fn {gym, membership} -> view(gym, membership, nil) end),
         next_cursor: if(rest == [], do: nil, else: rows |> List.last() |> encode_cursor())
       }}
    end
  end

  @doc "One gym, for one of its active staff (`:not_found` otherwise)."
  @spec get_gym(User.t(), term()) :: {:ok, view()} | {:error, :not_found}
  def get_gym(%User{} = user, gym_id) do
    with {:ok, %{gym: gym, membership: membership}} <-
           Access.authorize(user, gym_id, :view_workspace) do
      {:ok, view(gym, membership, locations(gym.id))}
    end
  end

  ## Entry (SF-84)

  @typedoc """
  A gym workspace as the entry resolver and a workspace chooser see it: only
  the viewer's own facts (role, setup state) and the gym's name.
  """
  @type workspace_summary :: %{
          gym_id: Ecto.UUID.t(),
          name: String.t(),
          role: StaffMembership.role(),
          setup_status: Gym.setup_status(),
          available_actions: [:enter | :continue_setup]
        }

  @typedoc "The viewer's gym workspaces, for entry resolution."
  @type workspace_overview :: %{
          total: non_neg_integer(),
          completed_count: non_neg_integer(),
          single_completed_gym_id: Ecto.UUID.t() | nil,
          open_draft_gym_id: Ecto.UUID.t() | nil,
          entries: [workspace_summary()]
        }

  @doc """
  The viewer's gym workspaces for entry resolution (ADR 0026, SF-84): every
  active staff membership, counted, and at most `limit` summaries (the
  viewer's own open draft first, then newest membership first; the complete
  paginated list is `list_my_gyms/2`). `completed_count` counts gyms with a
  completed setup, which alone make an operational workspace;
  `open_draft_gym_id` is the draft the viewer owns (at most one, D-G25).
  Read-only, and only the viewer's own memberships are read.
  """
  @spec workspace_overview(User.t(), pos_integer()) :: workspace_overview()
  def workspace_overview(%User{id: user_id}, limit)
      when is_binary(user_id) and is_integer(limit) and limit > 0 do
    active =
      from(m in StaffMembership,
        join: g in Gym,
        on: g.id == m.gym_id,
        where: m.user_id == ^user_id and m.status == :active
      )

    # One statement, one snapshot: the counts, the single completed gym and
    # the owned draft always describe the same moment (separate statements
    # could straddle a concurrent completion, SF-85).
    {total, completed_count, first_completed_gym_id, open_draft_gym_id} =
      Repo.one(
        from([m, g] in active,
          select: {
            count(m.id),
            filter(count(m.id), g.setup_status == :completed),
            fragment(
              "(array_agg(?) FILTER (WHERE ? = 'completed'))[1]",
              g.id,
              g.setup_status
            ),
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC) FILTER (WHERE ? = 'draft' AND ? = 'owner'))[1]",
              g.id,
              m.inserted_at,
              m.id,
              g.setup_status,
              m.role
            )
          }
        )
      )

    single_completed_gym_id = if completed_count == 1, do: cast_uuid(first_completed_gym_id)
    open_draft_gym_id = cast_uuid(open_draft_gym_id)

    entries =
      from([m, g] in active,
        order_by: [
          desc: g.setup_status == :draft and m.role == :owner,
          desc: m.inserted_at,
          desc: m.id
        ],
        limit: ^limit,
        select: {g, m}
      )
      |> Repo.all(log: false)
      |> Enum.map(fn {gym, membership} -> workspace_summary(gym, membership) end)

    %{
      total: total,
      completed_count: completed_count,
      single_completed_gym_id: single_completed_gym_id,
      open_draft_gym_id: open_draft_gym_id,
      entries: entries
    }
  end

  @doc """
  The viewer's workspace at one gym, if they hold an active staff membership
  there: `{:ok, summary}`, otherwise `{:error, :not_found}` (an unknown,
  malformed or foreign id is never distinguished). Read-only.
  """
  @spec workspace(User.t(), term()) :: {:ok, workspace_summary()} | {:error, :not_found}
  def workspace(%User{} = user, gym_id) do
    with {:ok, %{gym: gym, membership: membership}} <-
           Access.authorize(user, gym_id, :view_workspace) do
      {:ok, workspace_summary(gym, membership)}
    end
  end

  @doc """
  Like `workspace/2`, inside the caller's transaction, holding a share lock
  on the viewer's membership until the transaction ends: a concurrent
  revocation (which locks the membership for update) commits either before,
  and this answers `:not_found`, or after the caller's transaction.
  """
  @spec lock_workspace(User.t(), term()) :: {:ok, workspace_summary()} | {:error, :not_found}
  def lock_workspace(%User{} = user, gym_id) do
    with {:ok, %{gym: gym, membership: membership}} <- Access.lock_shared(user, gym_id) do
      {:ok, workspace_summary(gym, membership)}
    end
  end

  defp cast_uuid(nil), do: nil
  defp cast_uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp cast_uuid(id) when is_binary(id), do: id

  defp workspace_summary(%Gym{} = gym, %StaffMembership{} = membership) do
    %{
      gym_id: gym.id,
      name: gym.name,
      role: membership.role,
      setup_status: gym.setup_status,
      available_actions: available_actions(gym.setup_status, membership.role)
    }
  end

  # Truthful entry actions: an operational (completed) gym can be entered;
  # a draft only continues setup, for the role that completes setup.
  defp available_actions(:completed, _role), do: [:enter]

  defp available_actions(:draft, role),
    do: if(Policy.grant(role, :complete_setup), do: [:continue_setup], else: [])

  ## Authorization

  @doc """
  Whether `user` may perform `permission` at the gym `gym_id`: the gym, the
  user's active membership and the grant's scope, or `:not_found` /
  `:forbidden` (see the module documentation). Read-only; operations that
  change gym state use the locking variant inside their transaction.
  """
  @spec authorize(User.t(), term(), Policy.permission()) ::
          {:ok, Access.t()} | {:error, :not_found | :forbidden}
  defdelegate authorize(user, gym_id, permission), to: Access

  ## Commerce (SF-101)

  @doc """
  The gym write transaction for `SimpleFit.Billing` (the gym's SaaS
  subscription): the caller's session held, the gym and the actor's staff
  membership locked, `permission` checked, a completed gym, 30 billing
  writes per 10 minutes per user. See `SimpleFit.Gyms.Guarded`.
  """
  @spec billing_write(User.t(), Session.t(), term(), Policy.permission(), (Access.t() ->
                                                                             {:ok, term()}
                                                                             | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def billing_write(%User{} = user, %Session{} = session, gym_id, permission, fun),
    do: Guarded.write(user, session, gym_id, permission, {"gym_billing_user", 30, 600}, fun)

  @doc "See `SimpleFit.Gyms.Access.lock_gym_shared/1` (SF-102 reconciliation lock order)."
  @spec lock_gym_shared(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  defdelegate lock_gym_shared(gym_id), to: Access

  @doc """
  Records a commercial gym audit event (SF-101) inside the caller's
  transaction: ids only (`saas_subscription_id`, `member_product_*`), never
  an amount, a provider reference or a person's details.
  """
  @spec record_commerce_event!(map(), DateTime.t()) :: :ok
  def record_commerce_event!(attrs, occurred_at), do: Audit.record!(attrs, occurred_at)

  @doc "See `SimpleFit.Gyms.Commerce.list_products/3`."
  defdelegate list_member_products(user, gym_id, params), to: Commerce, as: :list_products
  @doc "See `SimpleFit.Gyms.Commerce.get_product/3`."
  defdelegate get_member_product(user, gym_id, product_id), to: Commerce, as: :get_product
  @doc "See `SimpleFit.Gyms.Commerce.create_product/4`."
  defdelegate create_member_product(user, session, gym_id, attrs),
    to: Commerce,
    as: :create_product

  @doc "See `SimpleFit.Gyms.Commerce.create_version/5`."
  defdelegate create_member_product_version(user, session, gym_id, product_id, attrs),
    to: Commerce,
    as: :create_version

  @doc "See `SimpleFit.Gyms.Commerce.publish_version/5`."
  defdelegate publish_member_product_version(user, session, gym_id, product_id, version_id),
    to: Commerce,
    as: :publish_version

  @doc "See `SimpleFit.Gyms.Commerce.add_price/6`."
  defdelegate add_member_product_price(user, session, gym_id, product_id, version_id, attrs),
    to: Commerce,
    as: :add_price

  @doc "See `SimpleFit.Gyms.Commerce.retire_product/4`."
  defdelegate retire_member_product(user, session, gym_id, product_id),
    to: Commerce,
    as: :retire_product

  @doc "See `SimpleFit.Gyms.Commerce.list_subscriptions/3`."
  defdelegate list_member_product_subscriptions(user, gym_id, params),
    to: Commerce,
    as: :list_subscriptions

  @doc "See `SimpleFit.Gyms.Commerce.list_offers/2`."
  defdelegate list_my_gym_products(user, gym_member_id), to: Commerce, as: :list_offers

  @doc "See `SimpleFit.Gyms.Commerce.request_subscription/4`."
  defdelegate request_member_product_subscription(user, session, gym_member_id, attrs),
    to: Commerce,
    as: :request_subscription

  @doc "See `SimpleFit.Gyms.Commerce.list_mine/2`."
  defdelegate list_my_product_subscriptions(user, params), to: Commerce, as: :list_mine

  @doc "See `SimpleFit.Gyms.Commerce.cancel_mine/3`."
  defdelegate cancel_my_product_subscription(user, session, subscription_id),
    to: Commerce,
    as: :cancel_mine

  ## Ownership and staff

  @doc "See `SimpleFit.Gyms.Ownership.transfer/4`."
  @spec transfer_ownership(User.t(), term(), term(), Ownership.previous_owner()) ::
          {:ok, %{owner: StaffMembership.t(), previous_owner: StaffMembership.t() | nil}}
          | {:error, :not_found | :forbidden | {:conflict, map()}}
  defdelegate transfer_ownership(actor, gym_id, target_staff_membership_id, previous_owner),
    to: Ownership,
    as: :transfer

  @doc "See `SimpleFit.Gyms.Ownership.revoke/3`."
  @spec revoke_staff_membership(User.t(), term(), term()) ::
          {:ok, StaffMembership.t()} | {:error, :not_found | :forbidden | {:conflict, map()}}
  defdelegate revoke_staff_membership(actor, gym_id, staff_membership_id),
    to: Ownership,
    as: :revoke

  @doc """
  Ends a staff membership at a gym: another member's (removal) or the
  actor's own (leaving). See `SimpleFit.Gyms.Ownership.revoke/3`.
  """
  @spec end_staff_membership(User.t(), term(), term()) ::
          {:ok, StaffMembership.t()}
          | {:error,
             :not_found | :forbidden | {:conflict, map()} | {:rate_limited, pos_integer()}}
  defdelegate end_staff_membership(actor, gym_id, staff_membership_id),
    to: Ownership,
    as: :revoke

  ## Staff and invitations (SF-93)

  @doc "The gym's staff roster (see `SimpleFit.Gyms.Staff.list/3`)."
  @spec list_staff(User.t(), term(), map()) :: {:ok, Staff.page()} | {:error, term()}
  defdelegate list_staff(user, gym_id, params), to: Staff, as: :list

  @doc "Changes a staff member's role (see `SimpleFit.Gyms.Staff.change_role/4`)."
  @spec change_staff_role(User.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate change_staff_role(user, gym_id, staff_membership_id, attrs),
    to: Staff,
    as: :change_role

  @doc "Invites an email address to a staff role (see `SimpleFit.Gyms.StaffInvitations.create/4`)."
  @spec create_staff_invitation(User.t(), term(), map(), String.t()) ::
          {:ok, map(), :created | :existing} | {:error, StaffInvitations.error()}
  defdelegate create_staff_invitation(user, gym_id, attrs, client_ip),
    to: StaffInvitations,
    as: :create

  @doc "The gym's staff invitations (see `SimpleFit.Gyms.StaffInvitations.list/3`)."
  @spec list_staff_invitations(User.t(), term(), map()) ::
          {:ok, StaffInvitations.page()} | {:error, StaffInvitations.error()}
  defdelegate list_staff_invitations(user, gym_id, params), to: StaffInvitations, as: :list

  @doc "Sends a pending invitation again (see `SimpleFit.Gyms.StaffInvitations.resend/3`)."
  @spec resend_staff_invitation(User.t(), term(), term()) ::
          {:ok, map()} | {:error, StaffInvitations.error()}
  defdelegate resend_staff_invitation(user, gym_id, invitation_id),
    to: StaffInvitations,
    as: :resend

  @doc "Cancels a pending invitation (see `SimpleFit.Gyms.StaffInvitations.cancel/3`)."
  @spec cancel_staff_invitation(User.t(), term(), term()) ::
          {:ok, map()} | {:error, StaffInvitations.error()}
  defdelegate cancel_staff_invitation(user, gym_id, invitation_id),
    to: StaffInvitations,
    as: :cancel

  @doc "The staff invitations sent to the user's verified addresses (inbox)."
  @spec list_my_staff_invitations(User.t(), map()) ::
          {:ok, StaffInvitations.page()} | {:error, StaffInvitations.error()}
  defdelegate list_my_staff_invitations(user, params), to: StaffInvitations, as: :list_mine

  @doc "One staff invitation sent to the user's verified addresses."
  @spec get_my_staff_invitation(User.t(), term()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_my_staff_invitation(user, invitation_id), to: StaffInvitations, as: :get_mine

  @doc "What an E06 token shows before sign-in (see `SimpleFit.Gyms.StaffInvitations.preview/2`)."
  @spec preview_staff_invitation(term(), String.t()) ::
          {:ok, map()} | {:error, StaffInvitations.error()}
  defdelegate preview_staff_invitation(token, client_ip), to: StaffInvitations, as: :preview

  @doc "An E06 token's invitation for its signed-in recipient (see `SimpleFit.Gyms.StaffInvitations.resolve/3`)."
  @spec resolve_staff_invitation(User.t(), term(), String.t()) ::
          {:ok, map()} | {:error, StaffInvitations.error()}
  defdelegate resolve_staff_invitation(user, token, client_ip),
    to: StaffInvitations,
    as: :resolve

  @doc "The recipient's explicit acceptance (see `SimpleFit.Gyms.StaffInvitations.accept/4`)."
  @spec accept_staff_invitation(User.t(), Session.t(), {:token | :id, term()}, String.t()) ::
          {:ok, map()} | {:error, StaffInvitations.error()}
  defdelegate accept_staff_invitation(user, session, locator, client_ip),
    to: StaffInvitations,
    as: :accept

  @doc "The recipient declines (see `SimpleFit.Gyms.StaffInvitations.decline/3`)."
  @spec decline_staff_invitation(User.t(), {:token | :id, term()}, String.t()) ::
          {:ok, map()} | {:error, StaffInvitations.error()}
  defdelegate decline_staff_invitation(user, locator, client_ip),
    to: StaffInvitations,
    as: :decline

  ## Members (SF-95)

  @doc "The gym's members (see `SimpleFit.Gyms.Members.list/3`)."
  @spec list_members(User.t(), term(), map()) :: {:ok, Members.page()} | {:error, Members.error()}
  defdelegate list_members(user, gym_id, params), to: Members, as: :list

  @doc "One membership of the gym (see `SimpleFit.Gyms.Members.get/3`)."
  @spec get_member(User.t(), term(), term()) :: {:ok, map()} | {:error, Members.error()}
  defdelegate get_member(user, gym_id, member_id), to: Members, as: :get

  @doc "Ends a membership as the gym (see `SimpleFit.Gyms.Members.remove/3`)."
  @spec remove_member(User.t(), term(), term()) :: {:ok, map()} | {:error, Members.error()}
  defdelegate remove_member(user, gym_id, member_id), to: Members, as: :remove

  @doc "The gym's pending join requests (see `SimpleFit.Gyms.Members.list_requests/3`)."
  @spec list_join_requests(User.t(), term(), map()) ::
          {:ok, Members.page()} | {:error, Members.error()}
  defdelegate list_join_requests(user, gym_id, params), to: Members, as: :list_requests

  @doc "Approves a join request (see `SimpleFit.Gyms.Members.approve/3`)."
  @spec approve_join_request(User.t(), term(), term()) :: {:ok, map()} | {:error, Members.error()}
  defdelegate approve_join_request(user, gym_id, member_id), to: Members, as: :approve

  @doc "Rejects a join request (see `SimpleFit.Gyms.Members.reject/3`)."
  @spec reject_join_request(User.t(), term(), term()) :: {:ok, map()} | {:error, Members.error()}
  defdelegate reject_join_request(user, gym_id, member_id), to: Members, as: :reject

  @doc "The gym's enrollment settings (see `SimpleFit.Gyms.Members.get_settings/2`)."
  @spec get_enrollment_settings(User.t(), term()) :: {:ok, map()} | {:error, Members.error()}
  defdelegate get_enrollment_settings(user, gym_id), to: Members, as: :get_settings

  @doc "Changes auto-approval (see `SimpleFit.Gyms.Members.update_settings/3`)."
  @spec update_enrollment_settings(User.t(), term(), map()) ::
          {:ok, map()} | {:error, Members.error()}
  defdelegate update_enrollment_settings(user, gym_id, attrs), to: Members, as: :update_settings

  @doc "Issues a new join code (see `SimpleFit.Gyms.Members.rotate_join_code/2`)."
  @spec rotate_join_code(User.t(), term()) :: {:ok, map()} | {:error, Members.error()}
  defdelegate rotate_join_code(user, gym_id), to: Members

  @doc "Disables joining by code (see `SimpleFit.Gyms.Members.disable_join_code/2`)."
  @spec disable_join_code(User.t(), term()) :: {:ok, map()} | {:error, Members.error()}
  defdelegate disable_join_code(user, gym_id), to: Members

  @doc "The caller's own gym memberships (see `SimpleFit.Gyms.Members.list_mine/2`)."
  @spec list_my_gym_memberships(User.t(), map()) ::
          {:ok, Members.page()} | {:error, Members.error()}
  defdelegate list_my_gym_memberships(user, params), to: Members, as: :list_mine

  @doc "One of the caller's own gym memberships."
  @spec get_my_gym_membership(User.t(), term()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_my_gym_membership(user, member_id), to: Members, as: :get_mine

  @doc "What a join code shows (see `SimpleFit.Gyms.Members.preview_join/2`)."
  @spec preview_gym_join(term(), String.t()) :: {:ok, map()} | {:error, Members.error()}
  defdelegate preview_gym_join(code, client_ip), to: Members, as: :preview_join

  @doc "Joins a gym by code (see `SimpleFit.Gyms.Members.join/4`)."
  @spec join_gym(User.t(), Session.t(), term(), String.t()) ::
          {:ok, map(), :created | :existing} | {:error, Members.error()}
  defdelegate join_gym(user, session, code, client_ip), to: Members, as: :join

  @doc "Cancels the caller's own join request."
  @spec cancel_gym_join_request(User.t(), Session.t(), term()) ::
          {:ok, map()} | {:error, Members.error()}
  defdelegate cancel_gym_join_request(user, session, member_id), to: Members, as: :cancel_request

  @doc "Leaves a gym (the caller's own active membership)."
  @spec leave_gym_membership(User.t(), Session.t(), term()) ::
          {:ok, map()} | {:error, Members.error()}
  defdelegate leave_gym_membership(user, session, member_id), to: Members, as: :leave

  @doc "Invites an address to become a member (see `SimpleFit.Gyms.MemberInvitations.create/4`)."
  @spec create_member_invitation(User.t(), term(), map(), String.t()) ::
          {:ok, map(), :created | :existing} | {:error, MemberInvitations.error()}
  defdelegate create_member_invitation(user, gym_id, attrs, client_ip),
    to: MemberInvitations,
    as: :create

  @doc "The gym's member invitations."
  @spec list_member_invitations(User.t(), term(), map()) ::
          {:ok, MemberInvitations.page()} | {:error, MemberInvitations.error()}
  defdelegate list_member_invitations(user, gym_id, params), to: MemberInvitations, as: :list

  @doc "Sends a member invitation again."
  @spec resend_member_invitation(User.t(), term(), term()) ::
          {:ok, map()} | {:error, MemberInvitations.error()}
  defdelegate resend_member_invitation(user, gym_id, invitation_id),
    to: MemberInvitations,
    as: :resend

  @doc "Cancels a member invitation."
  @spec cancel_member_invitation(User.t(), term(), term()) ::
          {:ok, map()} | {:error, MemberInvitations.error()}
  defdelegate cancel_member_invitation(user, gym_id, invitation_id),
    to: MemberInvitations,
    as: :cancel

  @doc "The member invitations sent to the user's verified addresses (inbox)."
  @spec list_my_member_invitations(User.t(), map()) ::
          {:ok, MemberInvitations.page()} | {:error, MemberInvitations.error()}
  defdelegate list_my_member_invitations(user, params), to: MemberInvitations, as: :list_mine

  @doc "One member invitation sent to the user's verified addresses."
  @spec get_my_member_invitation(User.t(), term()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_my_member_invitation(user, invitation_id), to: MemberInvitations, as: :get_mine

  @doc "What an E07 token shows before sign-in."
  @spec preview_member_invitation(term(), String.t()) ::
          {:ok, map()} | {:error, MemberInvitations.error()}
  defdelegate preview_member_invitation(token, client_ip), to: MemberInvitations, as: :preview

  @doc "A member invitation link, for its signed-in recipient, in any status (SF-134)."
  @spec resolve_member_invitation(User.t(), term(), String.t()) ::
          {:ok, map()} | {:error, MemberInvitations.error()}
  defdelegate resolve_member_invitation(user, token, client_ip),
    to: MemberInvitations,
    as: :resolve

  @doc "The recipient's explicit acceptance of a member invitation."
  @spec accept_member_invitation(User.t(), Session.t(), {:token | :id, term()}, String.t()) ::
          {:ok, map()} | {:error, MemberInvitations.error()}
  defdelegate accept_member_invitation(user, session, locator, client_ip),
    to: MemberInvitations,
    as: :accept

  @doc "The recipient declines a member invitation."
  @spec decline_member_invitation(User.t(), {:token | :id, term()}, String.t()) ::
          {:ok, map()} | {:error, MemberInvitations.error()}
  defdelegate decline_member_invitation(user, locator, client_ip),
    to: MemberInvitations,
    as: :decline

  @doc "A dry-run preview of a member list (see `SimpleFit.Gyms.MemberImport`)."
  @spec preview_member_import(User.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate preview_member_import(user, gym_id, attrs), to: MemberImport, as: :preview

  ## Timetable (SF-97)

  @doc "See `SimpleFit.Gyms.Venues.list/3`."
  defdelegate list_venues(user, gym_id, params), to: Venues, as: :list
  @doc "See `SimpleFit.Gyms.Venues.get/3`."
  defdelegate get_venue(user, gym_id, venue_id), to: Venues, as: :get
  @doc "See `SimpleFit.Gyms.Venues.create/4`."
  defdelegate create_venue(user, session, gym_id, attrs), to: Venues, as: :create
  @doc "See `SimpleFit.Gyms.Venues.update/5`."
  defdelegate update_venue(user, session, gym_id, venue_id, attrs), to: Venues, as: :update
  @doc "See `SimpleFit.Gyms.Venues.deactivate/5`."
  defdelegate deactivate_venue(user, session, gym_id, venue_id, attrs),
    to: Venues,
    as: :deactivate

  @doc "See `SimpleFit.Gyms.ClassTemplates.list/3`."
  defdelegate list_class_templates(user, gym_id, params), to: ClassTemplates, as: :list
  @doc "See `SimpleFit.Gyms.ClassTemplates.get/3`."
  defdelegate get_class_template(user, gym_id, template_id), to: ClassTemplates, as: :get
  @doc "See `SimpleFit.Gyms.ClassTemplates.create/4`."
  defdelegate create_class_template(user, session, gym_id, attrs), to: ClassTemplates, as: :create
  @doc "See `SimpleFit.Gyms.ClassTemplates.update/5`."
  defdelegate update_class_template(user, session, gym_id, template_id, attrs),
    to: ClassTemplates,
    as: :update

  @doc "See `SimpleFit.Gyms.ClassTemplates.archive/5`."
  defdelegate archive_class_template(user, session, gym_id, template_id, attrs),
    to: ClassTemplates,
    as: :archive

  @doc "See `SimpleFit.Gyms.Timetable.list_series/3`."
  defdelegate list_class_series(user, gym_id, params), to: Timetable, as: :list_series
  @doc "See `SimpleFit.Gyms.Timetable.get_series/3`."
  defdelegate get_class_series(user, gym_id, series_id), to: Timetable, as: :get_series
  @doc "See `SimpleFit.Gyms.Timetable.create_series/4`."
  defdelegate create_class_series(user, session, gym_id, attrs), to: Timetable, as: :create_series
  @doc "See `SimpleFit.Gyms.Timetable.update_series/5`."
  defdelegate update_class_series(user, session, gym_id, series_id, attrs),
    to: Timetable,
    as: :update_series

  @doc "See `SimpleFit.Gyms.Timetable.cancel_series/5`."
  defdelegate cancel_class_series(user, session, gym_id, series_id, attrs),
    to: Timetable,
    as: :cancel_series

  @doc "See `SimpleFit.Gyms.Timetable.generate_series/4`."
  defdelegate generate_class_series(user, session, gym_id, series_id),
    to: Timetable,
    as: :generate_series

  @doc "See `SimpleFit.Gyms.Timetable.list_occurrences/3`."
  defdelegate list_class_occurrences(user, gym_id, params), to: Timetable, as: :list_occurrences
  @doc "See `SimpleFit.Gyms.Timetable.get_occurrence/3`."
  defdelegate get_class_occurrence(user, gym_id, occurrence_id),
    to: Timetable,
    as: :get_occurrence

  @doc "See `SimpleFit.Gyms.Timetable.create_occurrence/4`."
  defdelegate create_class_occurrence(user, session, gym_id, attrs),
    to: Timetable,
    as: :create_occurrence

  @doc "See `SimpleFit.Gyms.Timetable.update_occurrence/5`."
  defdelegate update_class_occurrence(user, session, gym_id, occurrence_id, attrs),
    to: Timetable,
    as: :update_occurrence

  @doc "See `SimpleFit.Gyms.Timetable.cancel_occurrence/5`."
  defdelegate cancel_class_occurrence(user, session, gym_id, occurrence_id, attrs),
    to: Timetable,
    as: :cancel_occurrence

  ## Class bookings and check-ins (SF-99)

  @doc "See `SimpleFit.Gyms.Bookings.list_classes/3`."
  defdelegate list_member_classes(user, member_id, params), to: Bookings, as: :list_classes

  @doc "See `SimpleFit.Gyms.Bookings.book/4`."
  defdelegate book_class(user, session, member_id, attrs), to: Bookings, as: :book

  @doc "See `SimpleFit.Gyms.Bookings.list_mine/2`."
  defdelegate list_my_class_bookings(user, params), to: Bookings, as: :list_mine

  @doc "See `SimpleFit.Gyms.Bookings.get_mine/2`."
  defdelegate get_my_class_booking(user, booking_id), to: Bookings, as: :get_mine

  @doc "See `SimpleFit.Gyms.Bookings.cancel_mine/3`."
  defdelegate cancel_my_class_booking(user, session, booking_id), to: Bookings, as: :cancel_mine

  @doc "See `SimpleFit.Gyms.Bookings.roster/4`."
  defdelegate class_roster(user, gym_id, occurrence_id, params), to: Bookings, as: :roster

  @doc "See `SimpleFit.Gyms.Bookings.book_for/5`."
  defdelegate book_class_for_member(user, session, gym_id, occurrence_id, attrs),
    to: Bookings,
    as: :book_for

  @doc "See `SimpleFit.Gyms.Bookings.cancel_for/4`."
  defdelegate cancel_class_booking(user, session, gym_id, booking_id),
    to: Bookings,
    as: :cancel_for

  @doc "See `SimpleFit.Gyms.Bookings.check_in/4`."
  defdelegate check_in_class_booking(user, session, gym_id, booking_id),
    to: Bookings,
    as: :check_in

  ## Account deletion

  @doc """
  The gym side of account deletion (D-G26): `:ok`, or `409 conflict`
  (`gym_ownership: transfer_required`) while the user is the active owner of
  a completed gym.

  Contract for the future account-deletion workflow (there is no
  account-deletion endpoint yet): inside its deletion transaction it must
  call this guard and stop on a conflict; then remove the user's draft gyms
  (D-G20) and end their other active staff memberships with reason
  `account_deleted`, through functions this context will add with that
  workflow. Until then the database itself refuses to delete a user who has
  any active staff membership (an active membership cannot lose its user),
  so no gym can be left without an owner; ended memberships keep their
  history with the user removed.

  Gym members (SF-95) follow the same rule: a `requested` or `active` gym
  membership blocks the user's deletion in the database. The workflow must
  first cancel the user's pending join requests and end their active gym
  memberships with reason `account_deleted` (a vocabulary the database
  already accepts); final memberships then keep their history with
  `user_id` set to NULL. Ending them must also release their class bookings
  still to come (`SimpleFit.Gyms.Bookings.release_member!/3`, as SF-95's own
  endings do); bookings and check-ins belong to the membership row, never to
  the user, so they keep their history without any personal field.
  """
  @spec check_account_deletion(User.t()) :: :ok | {:error, {:conflict, map()}}
  defdelegate check_account_deletion(user), to: Ownership

  ## Views

  defp view(gym, membership, locations) do
    base = %{
      id: gym.id,
      name: gym.name,
      gym_type: gym.gym_type,
      setup_status: gym.setup_status,
      inserted_at: gym.inserted_at,
      updated_at: gym.updated_at,
      viewer: %{
        staff_membership_id: membership.id,
        role: membership.role,
        permissions: Policy.permissions_of(membership.role)
      }
    }

    if locations, do: Map.put(base, :locations, Enum.map(locations, &location_view/1)), else: base
  end

  defp location_view(%GymLocation{} = location) do
    Map.take(location, [
      :id,
      :name,
      :country_code,
      :city,
      :address_line,
      :entrance_note,
      :is_primary
    ])
  end

  defp locations(gym_id) do
    Repo.all(
      from(l in GymLocation,
        where: l.gym_id == ^gym_id and is_nil(l.archived_at),
        order_by: [desc: l.is_primary, asc: l.inserted_at, asc: l.id]
      ),
      log: false
    )
  end

  ## Pages

  defp page_params(params) do
    types = %{limit: :integer, cursor: :string}

    changeset =
      {%{limit: @default_limit, cursor: nil}, types}
      |> Changeset.cast(params, Map.keys(types))
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

  defp seek(query, nil), do: query

  defp seek(query, {at, id}),
    do:
      from([m, _g] in query,
        where: m.inserted_at < ^at or (m.inserted_at == ^at and m.id < ^id)
      )

  defp encode_cursor({_gym, %StaffMembership{inserted_at: at, id: id}}),
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
end
