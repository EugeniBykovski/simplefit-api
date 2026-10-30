defmodule SimpleFit.Gyms.MemberInvitations do
  @moduledoc """
  Gym member invitations (E07) and the recipient's explicit answer (ADR
  0026, D-G08, D-G22; SF-95). Internal to `SimpleFit.Gyms`. Separate from
  staff invitations (`SimpleFit.Gyms.StaffInvitations`) and coach
  invitations: other table, token prefix (`sgm_`) and key salts.

  ## Lifecycle and expiry

  `pending` → `accepted` | `declined` | `cancelled` | `expired`, all terminal
  (the database forbids any later change). **Expiry (SF-95 decision): 7
  days from the last sending**, server time, the same rule as staff
  invitations (D-G12) and coach invitations: no separate member value was
  approved, and one rule for every gym invitation keeps the E06 and E07
  links predictable. A resend issues a new token and a new 7-day expiry. A
  pending invitation past `expires_at` is expired whatever its stored status
  says. An invitation grants nothing: only the recipient's acceptance
  activates a gym membership, in the transaction that consumes it.

  ## Delivery gate (E07 launch readiness)

  Creating and resending send E07, whose link opens the web page
  `/invite/gym`. Until that page and the in-app inbox exist, both are off
  unless `config :simple_fit, SimpleFit.Gyms, member_invitations: true` (dev
  and test; production only with `GYM_MEMBER_INVITATIONS=enabled`), and
  answer `409` (`member_invitation: recipient_flow_unavailable`) after the
  usual access checks. Fail closed: anything but `true` is off. Answering,
  previewing, listing and cancelling existing invitations are unaffected.

  ## Who

  Owner, managers and front desk (`manage_member_enrollment`) invite,
  list, resend and cancel; only a completed gym invites. The invitation is
  the gym's, not the inviter's: it stays valid if the inviting staff member
  later leaves (the gym can cancel it).

  ## One pending invitation per gym and address

  The same address again returns the pending invitation (no new token or
  email). An address of an active member of this gym is `409`
  (`gym_member: already_active`); an address whose owner has a pending join
  request may be invited (accepting approves that request). Different gyms
  are independent; the partial unique index is the final authority.

  ## Recipient binding (D-G08, D-G22)

  Only a signed-in user holding an **email identity** for the invited
  address (proved with a code) can accept or decline; holding the token is
  not enough, a provider's email claim never counts, and nothing is linked,
  merged or created. By inbox id an unknown or foreign invitation is
  `:not_found`; by token every unusable token is `:invitation_unavailable`
  and a current token held by another account
  `:invitation_recipient_mismatch`.

  Acceptance locks the session (`FOR SHARE`), the gym row (`FOR SHARE`),
  the invitation and the user's current membership (`FOR UPDATE`), needs a
  completed account (no Fighter or Coach profile), then inserts an `active`
  membership (`joined_via: invitation`) or approves the caller's pending
  request, consumes the invitation and records the audit events: all or
  nothing. Repeated, the same membership (`:already_accepted`).

  ## Abuse limits

  While D-G25 is open: creation 30 per hour and 100 per day per inviting
  user, 300 per day per gym, 3 per day per recipient address (any gym), 60
  per 10 minutes per client, counted only when an invitation is created
  (rolling windows); resend after 60 seconds, at most 3 resends; previews
  and answers 30 per 10 minutes per client; administration 120 per 10
  minutes per user.

  Nothing here logs a token, an address, a digest or an id.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.{Accounts, Email, RateLimit, Repo}
  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Email.Templates

  alias SimpleFit.Gyms.{
    Access,
    Audit,
    Gym,
    Member,
    MemberInvitation,
    Members,
    MemberSecrets,
    Paging,
    StaffMembership
  }

  @unlogged [log: false]

  @lifetime 7 * 24 * 60 * 60
  @resend_cooldown 60
  @max_sends 4

  @type error ::
          :not_found
          | :forbidden
          | :session_revoked
          | :invitation_unavailable
          | :invitation_recipient_mismatch
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | :service_unavailable
          | Changeset.t()

  @type page :: %{entries: [map()], next_cursor: String.t() | nil}

  @doc "The lifetime of an invitation, in seconds (7 days)."
  @spec lifetime() :: pos_integer()
  def lifetime, do: @lifetime

  ## Gym side

  @doc """
  Invites `attrs["email"]` to become a member (see the moduledoc).
  `{:ok, view, :created}` with a new invitation and its E07 email queued in
  the same transaction, or `{:ok, view, :existing}` for the same pending
  address.
  """
  @spec create(User.t(), term(), map(), String.t()) ::
          {:ok, map(), :created | :existing} | {:error, error()}
  def create(%User{} = user, gym_id, attrs, client_ip)
      when is_map(attrs) and is_binary(client_ip) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym, membership: inviter}} <-
               Access.authorize_locked(user, gym_id, :manage_member_enrollment),
             :ok <- delivery_enabled(),
             {:ok, address} <- create_params(attrs),
             :ok <- completed(gym),
             digest = MemberSecrets.recipient_digest(address),
             :ok <- expire_stale!(gym.id, digest),
             {:ok, nil} <- pending_for(gym.id, digest),
             :ok <- not_member(gym.id, address),
             :ok <- create_limits(user, gym, digest, client_ip) do
          {admin_view(insert!(gym, inviter, address, digest, user)), :created}
        else
          {:ok, %MemberInvitation{} = existing} -> {admin_view(existing), :existing}
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
    |> case do
      {:ok, {view, outcome}} ->
        emit(:created, %{outcome: outcome})
        {:ok, view, outcome}

      {:error, reason} ->
        emit(:refused, %{outcome: reason_tag(reason)})
        {:error, reason}
    end
  end

  @doc """
  The gym's member invitations, newest first, with their effective status
  and a masked address (params: `limit`, `cursor`, optional `status`).
  """
  @spec list(User.t(), term(), map()) :: {:ok, page()} | {:error, error()}
  def list(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym}} <- Access.authorize(user, gym_id, :manage_member_enrollment),
         {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, MemberInvitation.statuses()) do
      now = DateTime.utc_now()

      rows =
        from(i in MemberInvitation,
          where: i.gym_id == ^gym.id,
          order_by: [desc: i.inserted_at, desc: i.id],
          limit: ^(limit + 1)
        )
        |> with_status(status, now)
        |> Paging.seek(cursor, :inserted_at, :desc)
        |> Repo.all(@unlogged)

      {rows, next} = Paging.page(rows, limit, :inserted_at)
      names = inviter_names(rows)
      {:ok, %{entries: Enum.map(rows, &admin_view(&1, names, now)), next_cursor: next}}
    end
  end

  @doc """
  Sends a pending invitation again with a new token (the previous one stops
  working at once) and a new 7-day expiry. At most 3 resends, 60 seconds
  apart.
  """
  @spec resend(User.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def resend(%User{} = user, gym_id, invitation_id) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym}} <-
               Access.authorize_locked(user, gym_id, :manage_member_enrollment),
             :ok <- delivery_enabled(),
             {:ok, invitation} <- lock_of_gym(gym.id, invitation_id),
             {:ok, updated, token, address} <- rotate(invitation),
             :ok <- Members.admin_limit(user) do
          deliver!(gym, address, token, updated)
          admin_view(updated)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
    |> tap(&emit(:resent, outcome(&1)))
  end

  @doc """
  Cancels a pending invitation. Idempotent for an invitation already
  cancelled or expired; `409` once accepted or declined
  (`member_invitation: accepted | declined`).
  """
  @spec cancel(User.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def cancel(%User{} = user, gym_id, invitation_id) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym}} <-
               Access.authorize_locked(user, gym_id, :manage_member_enrollment),
             {:ok, invitation} <- lock_of_gym(gym.id, invitation_id),
             :ok <- Members.admin_limit(user),
             {:ok, cancelled} <- cancel_pending(invitation, user.id) do
          admin_view(cancelled)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
    |> tap(&emit(:cancelled, outcome(&1)))
  end

  defp cancel_pending(invitation, actor_user_id) do
    now = DateTime.utc_now()

    case MemberInvitation.effective_status(invitation, now) do
      :pending ->
        cancelled = respond!(invitation, now, status: :cancelled)
        audit!(invitation.gym_id, actor_user_id, :member_invitation_cancelled, cancelled, now)
        {:ok, cancelled}

      :expired ->
        {:ok, expire!(invitation, now)}

      :cancelled ->
        {:ok, invitation}

      resolved ->
        {:error, {:conflict, %{member_invitation: Atom.to_string(resolved)}}}
    end
  end

  ## Recipient side

  @doc """
  The member invitations addressed to the caller's verified email
  identities, newest first (params: `limit`, `cursor`, optional `status`).
  Reading changes nothing.
  """
  @spec list_mine(User.t(), map()) :: {:ok, page()} | {:error, error()}
  def list_mine(%User{} = user, params) when is_map(params) do
    with {:ok, %{limit: limit, cursor: cursor, status: status}} <-
           Paging.params(params, MemberInvitation.statuses()) do
      now = DateTime.utc_now()
      addresses = recipient_addresses(user)

      rows =
        case Map.keys(addresses) do
          [] ->
            []

          digests ->
            from(i in MemberInvitation,
              where: i.recipient_digest in ^digests,
              order_by: [desc: i.inserted_at, desc: i.id],
              limit: ^(limit + 1)
            )
            |> with_status(status, now)
            |> Paging.seek(cursor, :inserted_at, :desc)
            |> Repo.all(@unlogged)
        end

      {rows, next} = Paging.page(rows, limit, :inserted_at)
      context = recipient_context(rows)

      {:ok,
       %{
         entries: Enum.map(rows, &recipient_view(&1, addresses, context, now)),
         next_cursor: next
       }}
    end
  end

  @doc "One invitation addressed to the caller (any status), or `:not_found`."
  @spec get_mine(User.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def get_mine(%User{} = user, invitation_id) do
    addresses = recipient_addresses(user)

    with {:ok, id} <- Access.cast_id(invitation_id),
         %MemberInvitation{} = invitation <- Repo.one(mine_query(addresses, id), @unlogged) do
      {:ok,
       recipient_view(invitation, addresses, recipient_context([invitation]), DateTime.utc_now())}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  What the holder of an E07 token may see before signing in: the gym's
  name, the inviter's first name and role, and the expiry. Every token that
  is not a current pending one answers `:invitation_unavailable`.
  """
  @spec preview(term(), String.t()) :: {:ok, map()} | {:error, error()}
  def preview(token, client_ip) when is_binary(client_ip) do
    result =
      with :ok <- response_limit(client_ip),
           {:ok, hash} <- token_param(token),
           %MemberInvitation{} = invitation <-
             Repo.one(from(i in MemberInvitation, where: i.token_hash == ^hash), @unlogged),
           :pending <- MemberInvitation.effective_status(invitation, DateTime.utc_now()) do
        context = recipient_context([invitation])

        {:ok,
         %{
           gym: %{name: Map.get(context.gyms, invitation.gym_id)},
           invited_by: inviter_projection(invitation, context),
           expires_at: invitation.expires_at
         }}
      else
        {:error, {:rate_limited, _} = reason} -> {:error, reason}
        _ -> {:error, :invitation_unavailable}
      end

    emit(:previewed, outcome(result))
    result
  end

  @doc """
  The explicit acceptance, by token (`{:token, token}`) or inbox id
  (`{:id, id}`), for the signed-in recipient on `session`.
  """
  @spec accept(User.t(), Session.t(), {:token, term()} | {:id, term()}, String.t()) ::
          {:ok, map()} | {:error, error()}
  def accept(%User{} = user, %Session{} = session, locator, client_ip)
      when is_binary(client_ip) do
    result =
      with :ok <- response_limit(client_ip),
           {:ok, locator} <- locate(locator) do
        Repo.transaction(fn -> accept_locked(user, session, locator) end, @unlogged)
      end

    emit(:accepted, outcome(result))
    result
  end

  @doc "Declines an invitation, by token or inbox id, for its signed-in recipient."
  @spec decline(User.t(), {:token, term()} | {:id, term()}, String.t()) ::
          {:ok, map()} | {:error, error()}
  def decline(%User{} = user, locator, client_ip) when is_binary(client_ip) do
    result =
      with :ok <- response_limit(client_ip),
           {:ok, locator} <- locate(locator) do
        Repo.transaction(fn -> decline_locked(user, locator) end, @unlogged)
      end

    emit(:declined, outcome(result))
    result
  end

  defp accept_locked(user, session, locator) do
    with :ok <- Members.held(Accounts.hold_active_session(user, session)),
         {:ok, gym, invitation, addresses} <- lock_for_recipient(user, locator) do
      now = DateTime.utc_now()

      case answered_by(invitation, user, now) do
        :pending -> activate!(user, gym, invitation, addresses, now)
        {:accepted, member} -> acceptance(gym, invitation, member, addresses, :already_accepted)
        _other -> Repo.rollback(:invitation_unavailable)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp decline_locked(user, locator) do
    case lock_for_recipient(user, locator) do
      {:ok, gym, invitation, addresses} ->
        now = DateTime.utc_now()

        case answered_by(invitation, user, now) do
          :pending ->
            declined = respond!(invitation, now, status: :declined)
            audit!(gym.id, user.id, :member_invitation_declined, declined, now)
            recipient_view(declined, addresses, recipient_context([declined]), now)

          :declined ->
            recipient_view(invitation, addresses, recipient_context([invitation]), now)

          _other ->
            Repo.rollback(:invitation_unavailable)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Finds the invitation without a lock (to learn its gym), then locks the
  # gym row (shared) and the invitation, and checks the recipient.
  defp lock_for_recipient(user, locator) do
    addresses = recipient_addresses(user)

    query =
      case locator do
        {:token, hash} -> from(i in MemberInvitation, where: i.token_hash == ^hash)
        {:id, id} -> mine_query(addresses, id)
      end

    with %MemberInvitation{gym_id: gym_id} <- Repo.one(query, @unlogged),
         %Gym{} = gym <- Access.lock_gym_shared!(gym_id),
         %MemberInvitation{} = invitation <-
           Repo.one(from(i in query, lock: "FOR UPDATE"), @unlogged) do
      if Map.has_key?(addresses, invitation.recipient_digest),
        do: {:ok, gym, invitation, addresses},
        else: recipient_mismatch(invitation)
    else
      nil -> {:error, unknown(locator)}
    end
  end

  defp recipient_mismatch(invitation) do
    if MemberInvitation.effective_status(invitation, DateTime.utc_now()) == :pending,
      do: {:error, :invitation_recipient_mismatch},
      else: {:error, :invitation_unavailable}
  end

  defp unknown({:token, _hash}), do: :invitation_unavailable
  defp unknown({:id, _id}), do: :not_found

  defp answered_by(invitation, user, now) do
    case MemberInvitation.effective_status(invitation, now) do
      :accepted ->
        case Repo.get(Member, invitation.gym_member_id, @unlogged) do
          %Member{user_id: user_id, status: :active} = member when user_id == user.id ->
            {:accepted, member}

          _ ->
            :unavailable
        end

      other ->
        other
    end
  end

  defp activate!(user, gym, invitation, addresses, now) do
    with :ok <- Members.registered(user),
         {:ok, member, approved?} <- membership_for(gym, user, now) do
      accepted = respond!(invitation, now, status: :accepted, gym_member_id: member.id)
      audit!(gym.id, user.id, :member_invitation_accepted, accepted, now)

      if approved?,
        do: Members.audit!(gym.id, user.id, :member_join_approved, member, now, extra(accepted))

      acceptance(gym, accepted, member, addresses, :accepted)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A new active membership, or the caller's pending join request approved
  # by the gym's invitation. An active membership is a conflict (the
  # invitation stays pending). The partial unique index settles a
  # concurrent join or acceptance by the same user.
  defp membership_for(gym, user, now) do
    case Members.lock_current(gym.id, user.id) do
      nil ->
        row = %{
          id: Ecto.UUID.generate(),
          gym_id: gym.id,
          user_id: user.id,
          status: :active,
          joined_via: :invitation,
          auto_approved: false,
          activated_at: now,
          inserted_at: now,
          updated_at: now
        }

        case Members.insert_member(row) do
          {:ok, member} -> {:ok, member, false}
          :conflict -> membership_for(gym, user, now)
        end

      %Member{status: :requested} = requested ->
        {:ok, Members.activate!(requested, [status: :active, activated_at: now], now), true}

      %Member{status: :active} ->
        {:error, {:conflict, %{gym_member: "already_active"}}}
    end
  end

  defp acceptance(gym, invitation, member, addresses, outcome) do
    %{
      invitation:
        recipient_view(invitation, addresses, recipient_context([invitation]), DateTime.utc_now()),
      gym_id: gym.id,
      gym_member_id: member.id,
      outcome: outcome
    }
  end

  ## Creation

  defp insert!(gym, inviter, address, digest, user) do
    now = DateTime.utc_now()
    token = MemberSecrets.generate_token()

    {1, [invitation]} =
      Repo.insert_all(
        MemberInvitation,
        [
          %{
            id: Ecto.UUID.generate(),
            gym_id: gym.id,
            invited_by_staff_membership_id: inviter.id,
            token_hash: MemberSecrets.hash!(token),
            recipient_digest: digest,
            recipient_sealed: MemberSecrets.seal(address),
            status: :pending,
            expires_at: DateTime.add(now, @lifetime),
            send_count: 1,
            last_sent_at: now,
            inserted_at: now,
            updated_at: now
          }
        ],
        Keyword.merge(@unlogged, returning: true)
      )

    audit!(gym.id, user.id, :member_invited, invitation, now)
    deliver!(gym, address, token, invitation)
    invitation
  end

  defp create_params(attrs) do
    changeset =
      {%{}, %{email: :string}}
      |> Changeset.cast(attrs, [:email])
      |> Changeset.validate_required([:email])
      |> normalize_email()
      |> Members.reject_unknown_fields(attrs, ["email"])

    if changeset.valid?,
      do: {:ok, Changeset.get_field(changeset, :email)},
      else: {:error, changeset}
  end

  @doc false
  # The canonical address of an `:email` change, or an `is invalid` error.
  @spec normalize_email(Changeset.t()) :: Changeset.t()
  def normalize_email(changeset) do
    case Changeset.get_change(changeset, :email) do
      nil ->
        changeset

      email ->
        case Accounts.normalize_email(email) do
          {:ok, address} -> Changeset.put_change(changeset, :email, address)
          :error -> Changeset.add_error(changeset, :email, "is invalid", validation: :format)
        end
    end
  end

  @doc "Whether E07 member invitations may be sent (see the moduledoc)."
  @spec delivery_enabled?() :: boolean()
  def delivery_enabled?,
    do: Application.get_env(:simple_fit, SimpleFit.Gyms, [])[:member_invitations] == true

  defp delivery_enabled do
    if delivery_enabled?(),
      do: :ok,
      else: {:error, {:conflict, %{member_invitation: "recipient_flow_unavailable"}}}
  end

  defp completed(%Gym{setup_status: :completed}), do: :ok
  defp completed(%Gym{}), do: {:error, {:conflict, %{setup_status: "draft"}}}

  defp expire_stale!(gym_id, digest) do
    now = DateTime.utc_now()

    from(i in MemberInvitation,
      where:
        i.gym_id == ^gym_id and i.recipient_digest == ^digest and i.status == :pending and
          i.expires_at <= ^now
    )
    |> Repo.update_all([set: [status: :expired, updated_at: now]], @unlogged)

    :ok
  end

  @doc false
  # The pending invitation of an address at a gym (`{:ok, nil}` if none).
  @spec pending_for(Ecto.UUID.t(), binary()) :: {:ok, MemberInvitation.t() | nil}
  def pending_for(gym_id, digest) do
    {:ok,
     Repo.one(
       from(i in MemberInvitation,
         where: i.gym_id == ^gym_id and i.recipient_digest == ^digest and i.status == :pending
       ),
       @unlogged
     )}
  end

  @doc false
  # `:ok`, or a conflict when the address belongs to an active member of the
  # gym. The gym's staff learn this about their own members only, nothing
  # else about accounts.
  @spec not_member(Ecto.UUID.t(), String.t()) :: :ok | {:error, {:conflict, map()}}
  def not_member(gym_id, address) do
    case member_status(gym_id, address) do
      :active -> {:error, {:conflict, %{gym_member: "already_active"}}}
      _other -> :ok
    end
  end

  @doc false
  # The current membership status at the gym of the account holding the
  # email identity `address` (`:active`, `:requested`) or `nil`.
  @spec member_status(Ecto.UUID.t(), String.t()) :: :active | :requested | nil
  def member_status(gym_id, address) do
    case Accounts.resolve_user(:email, address) do
      {:ok, %User{id: user_id}} ->
        Repo.one(
          from(m in Member,
            where:
              m.gym_id == ^gym_id and m.user_id == ^user_id and
                m.status in [:requested, :active],
            select: m.status
          ),
          @unlogged
        )

      _ ->
        nil
    end
  end

  ## Gym-side locks and transitions

  defp lock_of_gym(gym_id, invitation_id) do
    with {:ok, id} <- Access.cast_id(invitation_id),
         %MemberInvitation{} = invitation <-
           Repo.one(
             from(i in MemberInvitation,
               where: i.id == ^id and i.gym_id == ^gym_id,
               lock: "FOR UPDATE"
             ),
             @unlogged
           ) do
      {:ok, invitation}
    else
      _ -> {:error, :not_found}
    end
  end

  defp rotate(invitation) do
    now = DateTime.utc_now()
    cooldown = @resend_cooldown - DateTime.diff(now, invitation.last_sent_at)

    cond do
      MemberInvitation.effective_status(invitation, now) != :pending ->
        {:error, {:conflict, %{member_invitation: "not_pending"}}}

      invitation.send_count >= @max_sends ->
        {:error, {:conflict, %{resends: "limit_reached"}}}

      cooldown > 0 ->
        {:error, {:rate_limited, cooldown}}

      true ->
        {:ok, address} = MemberSecrets.open(invitation.recipient_sealed)
        token = MemberSecrets.generate_token()

        {1, [updated]} =
          Repo.update_all(
            from(i in MemberInvitation, where: i.id == ^invitation.id, select: i),
            [
              set: [
                token_hash: MemberSecrets.hash!(token),
                expires_at: DateTime.add(now, @lifetime),
                last_sent_at: now,
                updated_at: now
              ],
              inc: [send_count: 1]
            ],
            @unlogged
          )

        {:ok, updated, token, address}
    end
  end

  defp expire!(invitation, now) do
    {1, [expired]} =
      Repo.update_all(
        from(i in MemberInvitation, where: i.id == ^invitation.id, select: i),
        [set: [status: :expired, updated_at: now]],
        @unlogged
      )

    expired
  end

  defp respond!(invitation, now, changes) do
    {1, [updated]} =
      Repo.update_all(
        from(i in MemberInvitation, where: i.id == ^invitation.id, select: i),
        [set: Keyword.merge(changes, responded_at: now, updated_at: now)],
        @unlogged
      )

    updated
  end

  defp audit!(gym_id, actor_user_id, event_type, invitation, now) do
    Audit.record!(
      Map.merge(
        %{gym_id: gym_id, actor_user_id: actor_user_id, event_type: event_type},
        extra(invitation)
      ),
      now
    )
  end

  defp extra(invitation),
    do: %{member_invitation_id: invitation.id, gym_member_id: invitation.gym_member_id}

  ## Email (E07)

  # Enqueued in the caller's transaction (an outbox): the job exists exactly
  # when the invitation (or its new token) commits. The payload is
  # encrypted (ADR 0011); the token travels only in the link's fragment.
  defp deliver!(gym, address, token, invitation) do
    config = Application.get_env(:simple_fit, SimpleFit.Gyms, [])

    rendered =
      Templates.member_invite(
        gym_name: gym.name,
        accept_url: "#{config[:web_app_url]}/invite/gym#token=#{token}",
        expires_on: DateTime.to_date(invitation.expires_at)
      )

    with {:ok, rendered} <- rendered,
         {:ok, message} <- Templates.to_message(rendered, to: address),
         {:ok, _job} <- Email.deliver_later(message) do
      :ok
    else
      {:error, _reason} -> Repo.rollback(:service_unavailable)
    end
  end

  ## Views

  defp admin_view(invitation),
    do: admin_view(invitation, inviter_names([invitation]), DateTime.utc_now())

  defp admin_view(%MemberInvitation{} = invitation, names, now) do
    status = MemberInvitation.effective_status(invitation, now)

    %{
      invitation_id: invitation.id,
      status: status,
      recipient_email: masked(invitation.recipient_sealed),
      invited_by: %{
        staff_membership_id: invitation.invited_by_staff_membership_id,
        name: Map.get(names, invitation.invited_by_staff_membership_id)
      },
      created_at: invitation.inserted_at,
      expires_at: invitation.expires_at,
      last_sent_at: invitation.last_sent_at,
      resends_remaining:
        if(status == :pending, do: max(@max_sends - invitation.send_count, 0), else: 0),
      responded_at: invitation.responded_at,
      gym_member_id: invitation.gym_member_id
    }
  end

  defp inviter_names(invitations) do
    memberships =
      Repo.all(
        from(m in StaffMembership,
          where: m.id in ^Enum.map(invitations, & &1.invited_by_staff_membership_id),
          select: {m.id, m.user_id}
        ),
        @unlogged
      )

    names =
      memberships |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Accounts.short_names()

    Map.new(memberships, fn {id, user_id} -> {id, get_in(names, [user_id, :short_name])} end)
  end

  defp recipient_context(invitations) do
    gyms =
      Repo.all(
        from(g in Gym,
          where: g.id in ^Enum.map(invitations, & &1.gym_id),
          select: {g.id, g.name}
        ),
        @unlogged
      )
      |> Map.new()

    inviters =
      Repo.all(
        from(m in StaffMembership,
          where: m.id in ^Enum.map(invitations, & &1.invited_by_staff_membership_id),
          select: {m.id, {m.user_id, m.role}}
        ),
        @unlogged
      )
      |> Map.new()

    names =
      inviters
      |> Map.values()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&is_nil/1)
      |> Accounts.short_names()

    %{gyms: gyms, inviters: inviters, names: names}
  end

  defp inviter_projection(invitation, context) do
    case Map.get(context.inviters, invitation.invited_by_staff_membership_id) do
      {user_id, role} -> %{first_name: get_in(context.names, [user_id, :first_name]), role: role}
      nil -> %{first_name: nil, role: nil}
    end
  end

  defp recipient_view(invitation, addresses, context, now) do
    %{
      invitation_id: invitation.id,
      status: MemberInvitation.effective_status(invitation, now),
      gym: %{gym_id: invitation.gym_id, name: Map.get(context.gyms, invitation.gym_id)},
      invited_by: inviter_projection(invitation, context),
      sent_to: Map.get(addresses, invitation.recipient_digest),
      created_at: invitation.inserted_at,
      expires_at: invitation.expires_at,
      responded_at: invitation.responded_at,
      gym_member_id: invitation.gym_member_id
    }
  end

  @doc false
  # "n•••@example.com" for a sealed address.
  @spec masked(String.t()) :: String.t()
  def masked(sealed) do
    case MemberSecrets.open(sealed) do
      {:ok, address} -> mask(address)
      :error -> "•••"
    end
  end

  @doc false
  @spec mask(String.t()) :: String.t()
  def mask(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] -> String.first(local) <> "•••@" <> domain
      _ -> "•••"
    end
  end

  defp recipient_addresses(user) do
    user
    |> Accounts.verified_email_addresses()
    |> Map.new(&{MemberSecrets.recipient_digest(&1), &1})
  end

  defp mine_query(addresses, id) do
    digests = Map.keys(addresses)
    from(i in MemberInvitation, where: i.id == ^id and i.recipient_digest in ^digests)
  end

  defp locate({:token, token}) do
    with {:ok, hash} <- token_param(token), do: {:ok, {:token, hash}}
  end

  defp locate({:id, id}) do
    case Access.cast_id(id) do
      {:ok, id} -> {:ok, {:id, id}}
      :error -> {:error, :not_found}
    end
  end

  defp token_param(token) do
    case MemberSecrets.token_hash(token) do
      {:ok, hash} -> {:ok, hash}
      :error -> {:error, :invitation_unavailable}
    end
  end

  ## Limits

  defp create_limits(user, gym, digest, client_ip) do
    RateLimit.hit_rolling([
      {"gym_member_invite_client", key("client", client_ip), 60, 600},
      {"gym_member_invite_user_hour", key("user", user.id), 30, 3600},
      {"gym_member_invite_user_day", key("user", user.id), 100, 86_400},
      {"gym_member_invite_gym_day", key("gym", gym.id), 300, 86_400},
      {"gym_member_invite_recipient_day", key("recipient", Base.encode64(digest)), 3, 86_400}
    ])
  end

  defp response_limit(client_ip),
    do: RateLimit.hit([{"gym_member_invite_response_client", key("client", client_ip), 30, 600}])

  defp key(kind, value), do: MemberSecrets.rate_limit_key(kind, value)

  ## Paging

  defp with_status(query, nil, _now), do: query

  defp with_status(query, :pending, now),
    do: from(i in query, where: i.status == :pending and i.expires_at > ^now)

  defp with_status(query, :expired, now),
    do:
      from(i in query,
        where: i.status == :expired or (i.status == :pending and i.expires_at <= ^now)
      )

  defp with_status(query, status, _now), do: from(i in query, where: i.status == ^status)

  ## Telemetry

  defp outcome({:ok, _}), do: %{outcome: :ok}
  defp outcome({:error, reason}), do: %{outcome: reason_tag(reason)}

  defp reason_tag(%Changeset{}), do: :validation_error
  defp reason_tag({:conflict, _}), do: :conflict
  defp reason_tag({:rate_limited, _}), do: :rate_limited
  defp reason_tag(reason) when is_atom(reason), do: reason

  # Outcomes only: never a token, address, digest or id.
  defp emit(event, metadata),
    do: :telemetry.execute([:simple_fit, :gyms, :member_invitation, event], %{count: 1}, metadata)
end
