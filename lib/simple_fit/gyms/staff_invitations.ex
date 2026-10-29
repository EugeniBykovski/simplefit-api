defmodule SimpleFit.Gyms.StaffInvitations do
  @moduledoc """
  Gym staff invitations and the recipient's explicit answer (ADR 0026,
  D-G12, D-G16, D-G22; SF-93). Internal to `SimpleFit.Gyms`.

  ## Lifecycle

  `pending` → `accepted` | `declined` | `cancelled` | `expired`, all terminal
  (the database forbids any later change). A pending invitation past
  `expires_at` (7 days from its last sending, D-G12; server time) is expired
  whatever its stored status says; the stored status catches up when the
  invitation is next touched. An invitation grants nothing: only acceptance
  creates a staff membership, in the transaction that consumes it.

  ## Who invites whom (`SimpleFit.Gyms.Policy`)

  The owner invites managers, coaches and front desk (`invite_manager`,
  `invite_staff`); a manager coaches and front desk; other roles nobody.
  Nobody is invited as `owner` (D-G04: ownership moves only by a transfer).
  Only a completed gym invites (a draft answers `setup_status: draft`).
  Cancelling and resending need the same permission as inviting that role.
  When the inviting membership ends, or its new role can no longer invite
  that role, its pending invitations are cancelled in the same transaction.

  ## One pending invitation per gym and address

  The same address and role again returns the pending invitation (no new
  token or email: a lost response or a double click is safe); another role
  is `409` (`staff_invitation: pending_other_role`; cancel and invite
  again). An address that already belongs to an active member of this gym is
  `409` (`staff_membership: already_active`). Different gyms are
  independent. The gym row lock serializes every invitation write of a gym,
  and the partial unique index is the final authority.

  ## Recipient binding (D-G16, D-G22)

  The address is stored as an HMAC digest and a sealed copy. Only a
  signed-in user holding an **email identity** for that exact address (an
  address they proved with a code: ADR 0012 at sign-up, ADR 0024 when
  linking it to a Google or Apple account) can accept or decline. Holding the
  token is not enough, a provider's email claim never counts, and nothing is
  ever linked, merged or created. Opening, previewing or listing an
  invitation changes nothing.

  Two ways to answer, one transaction:

    * **By id from the inbox** (mobile, D-G22): `list_mine/2` shows only the
      invitations addressed to the caller's verified addresses; an unknown or
      foreign id is `:not_found`.
    * **By token** (the web page of the E06 link, `#token=` fragment, read
      once): unknown, rotated, used, declined, cancelled and expired tokens
      all answer `:invitation_unavailable` (no state oracle); a current token
      held by another account answers `:invitation_recipient_mismatch`.

  Acceptance locks the user's session (`FOR SHARE`, so a logout commits
  before or after it), then the gym row (`FOR UPDATE`, the SF-83 order),
  then the invitation (`FOR UPDATE`), re-checks everything, inserts the
  membership, consumes the invitation and records the audit events: all or
  nothing. A repeated acceptance by the same person returns the same
  membership (`:already_accepted`).

  ## Abuse limits

  Mirroring coach invitations (SF-57) while D-G25 is open: creation 10 per
  hour and 30 per day per inviting user, 100 per day per gym, 3 per day per
  recipient address (any gym), 20 per 10 minutes per client, counted only
  when an invitation is created (rolling windows, SF-83); resend after 60
  seconds, at most 3 resends; previews and answers 30 per 10 minutes per
  client; staff administration 60 per 10 minutes per user.

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
    InvitationSecrets,
    Policy,
    StaffInvitation,
    StaffMembership
  }

  @unlogged [log: false]

  @lifetime 7 * 24 * 60 * 60
  @resend_cooldown 60
  @max_sends 4
  @default_limit 50
  @max_limit 100

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

  ## Gym side

  @doc """
  Invites `attrs["email"]` to `attrs["role"]` at the gym (see the moduledoc).
  `{:ok, view, :created}` with a new invitation and its E06 email queued in
  the same transaction, or `{:ok, view, :existing}` for the same pending
  address and role.
  """
  @spec create(User.t(), term(), map(), String.t()) ::
          {:ok, map(), :created | :existing} | {:error, error()}
  def create(%User{} = user, gym_id, attrs, client_ip)
      when is_map(attrs) and is_binary(client_ip) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym, membership: inviter}} <-
               Access.authorize_locked(user, gym_id, :invite_staff),
             {:ok, params} <- create_params(attrs, user),
             {:ok, _scope} <- Policy.check(inviter, permission_for(params.role)),
             :ok <- completed(gym),
             digest = InvitationSecrets.recipient_digest(params.email),
             :ok <- expire_stale!(gym.id, digest),
             {:ok, nil} <- pending_for(gym.id, digest, params.role),
             :ok <- not_staff(gym.id, params.email),
             :ok <- create_limits(user, gym, digest, client_ip) do
          invitation = insert!(gym, inviter, params, digest, user)
          {admin_view(invitation), :created}
        else
          {:ok, %StaffInvitation{} = existing} -> {admin_view(existing), :existing}
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
        emit(:refused, %{reason: reason_tag(reason)})
        {:error, reason}
    end
  end

  @doc """
  The gym's invitations, newest first, with their effective status and a
  masked address (params: `limit`, `cursor`, optional `status`). Owner and
  managers only (`view_staff_records`).
  """
  @spec list(User.t(), term(), map()) :: {:ok, page()} | {:error, error()}
  def list(%User{} = user, gym_id, params) when is_map(params) do
    with {:ok, %{gym: gym}} <- Access.authorize(user, gym_id, :view_staff_records),
         {:ok, %{limit: limit, cursor: cursor, status: status}} <- list_params(params) do
      now = DateTime.utc_now()

      rows =
        from(i in StaffInvitation,
          where: i.gym_id == ^gym.id,
          order_by: [desc: i.inserted_at, desc: i.id],
          limit: ^(limit + 1)
        )
        |> with_status(status, now)
        |> seek(cursor)
        |> Repo.all(@unlogged)

      {rows, rest} = Enum.split(rows, limit)
      names = inviter_names(rows)

      {:ok,
       %{
         entries: Enum.map(rows, &admin_view(&1, names, now)),
         next_cursor: if(rest == [], do: nil, else: encode_cursor(List.last(rows)))
       }}
    end
  end

  @doc """
  Sends a pending invitation again with a new token (the previous one stops
  working at once) and a new 7-day expiry. At most 3 resends, 60 seconds
  apart; the same permission as inviting that role.
  """
  @spec resend(User.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def resend(%User{} = user, gym_id, invitation_id) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym, membership: actor}} <-
               Access.authorize_locked(user, gym_id, :invite_staff),
             {:ok, invitation} <- lock_of_gym(gym.id, invitation_id),
             {:ok, _scope} <- Policy.check(actor, permission_for(invitation.role)),
             {:ok, updated, token, address} <- rotate(invitation),
             :ok <- admin_limit(user) do
          deliver!(gym, inviter_of(updated), address, token, updated)
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
  Cancels a pending invitation: it can no longer be accepted. Idempotent for
  an invitation already cancelled or expired; `409` once accepted or
  declined (`staff_invitation: accepted | declined`). The same permission as
  inviting that role.
  """
  @spec cancel(User.t(), term(), term()) :: {:ok, map()} | {:error, error()}
  def cancel(%User{} = user, gym_id, invitation_id) do
    Repo.transaction(
      fn ->
        with {:ok, %{gym: gym, membership: actor}} <-
               Access.authorize_locked(user, gym_id, :invite_staff),
             {:ok, invitation} <- lock_of_gym(gym.id, invitation_id),
             {:ok, _scope} <- Policy.check(actor, permission_for(invitation.role)),
             :ok <- admin_limit(user),
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

    case StaffInvitation.effective_status(invitation, now) do
      :pending -> {:ok, cancel!(invitation, actor_user_id, now)}
      :expired -> {:ok, expire!(invitation, now)}
      :cancelled -> {:ok, invitation}
      resolved -> {:error, {:conflict, %{staff_invitation: Atom.to_string(resolved)}}}
    end
  end

  @doc """
  Inside a staff write holding the gym row: cancels the pending invitations
  `membership` issued that its `role` can no longer issue (every one when
  the membership ended, `role` `nil`), as `actor_user_id`. Returns how many.
  """
  @spec cancel_issued_by!(
          StaffMembership.t(),
          StaffMembership.role() | nil,
          Ecto.UUID.t(),
          DateTime.t()
        ) ::
          non_neg_integer()
  def cancel_issued_by!(%StaffMembership{} = membership, role, actor_user_id, now) do
    true = Repo.in_transaction?()

    keep =
      if role,
        do: Enum.filter(StaffInvitation.roles(), &Policy.grant(role, permission_for(&1))),
        else: []

    from(i in StaffInvitation,
      where:
        i.invited_by_staff_membership_id == ^membership.id and i.status == :pending and
          i.role not in ^keep,
      lock: "FOR UPDATE"
    )
    |> Repo.all(@unlogged)
    |> Enum.map(fn invitation ->
      case StaffInvitation.effective_status(invitation, now) do
        :pending -> cancel!(invitation, actor_user_id, now)
        :expired -> expire!(invitation, now)
      end
    end)
    |> length()
  end

  ## Recipient side

  @doc """
  The invitations addressed to the caller's verified email identities,
  newest first, with their effective status (params: `limit`, `cursor`,
  optional `status`). Derived on the server from the session's user: a user
  without an email identity has an empty inbox. Reading changes nothing.
  """
  @spec list_mine(User.t(), map()) :: {:ok, page()} | {:error, error()}
  def list_mine(%User{} = user, params) when is_map(params) do
    with {:ok, %{limit: limit, cursor: cursor, status: status}} <- list_params(params) do
      now = DateTime.utc_now()
      addresses = recipient_addresses(user)

      rows =
        case Map.keys(addresses) do
          [] ->
            []

          digests ->
            from(i in StaffInvitation,
              where: i.recipient_digest in ^digests,
              order_by: [desc: i.inserted_at, desc: i.id],
              limit: ^(limit + 1)
            )
            |> with_status(status, now)
            |> seek(cursor)
            |> Repo.all(@unlogged)
        end

      {rows, rest} = Enum.split(rows, limit)
      context = recipient_context(rows)

      {:ok,
       %{
         entries: Enum.map(rows, &recipient_view(&1, addresses, context, now)),
         next_cursor: if(rest == [], do: nil, else: encode_cursor(List.last(rows)))
       }}
    end
  end

  @doc """
  One invitation addressed to the caller (any status), or `:not_found` for
  an unknown id or one sent to an address the caller has not verified.
  """
  @spec get_mine(User.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def get_mine(%User{} = user, invitation_id) do
    addresses = recipient_addresses(user)

    with {:ok, id} <- Access.cast_id(invitation_id) |> found(),
         %StaffInvitation{} = invitation <- Repo.one(mine_query(addresses, id), @unlogged) do
      {:ok,
       recipient_view(invitation, addresses, recipient_context([invitation]), DateTime.utc_now())}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  What the holder of an E06 token may see before signing in: the gym's name,
  the role, the inviter's first name and the expiry (T9). Nothing about the
  recipient or any account. Every token that is not a current pending one
  answers `:invitation_unavailable`.
  """
  @spec preview(term(), String.t()) :: {:ok, map()} | {:error, error()}
  def preview(token, client_ip) when is_binary(client_ip) do
    result =
      with :ok <- response_limit(client_ip),
           {:ok, hash} <- token_param(token),
           %StaffInvitation{} = invitation <-
             Repo.one(from(i in StaffInvitation, where: i.token_hash == ^hash), @unlogged),
           :pending <- StaffInvitation.effective_status(invitation, DateTime.utc_now()) do
        {:ok, preview_view(invitation, recipient_context([invitation]))}
      else
        {:error, {:rate_limited, _} = reason} -> {:error, reason}
        _ -> {:error, :invitation_unavailable}
      end

    emit(:previewed, outcome(result))
    result
  end

  @doc """
  The explicit acceptance, by token (`{:token, token}`) or by inbox id
  (`{:id, id}`), for the signed-in recipient on `session` (see the
  moduledoc). `{:ok, result}` with `outcome` `:accepted`, or
  `:already_accepted` when this person accepted it before (a lost response).
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

  @doc """
  Declines an invitation, by token or inbox id, for its signed-in
  recipient. Creates nothing. Repeated by the same person, the same answer.
  """
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

  ## Accept and decline

  defp accept_locked(user, session, locator) do
    with :ok <- held(Accounts.hold_active_session(user, session)),
         {:ok, gym, invitation, addresses} <- lock_for_recipient(user, locator) do
      now = DateTime.utc_now()

      case answered_by(invitation, user, now) do
        :pending ->
          activate!(user, gym, invitation, addresses, now)

        {:accepted, membership} ->
          acceptance(gym, invitation, membership, addresses, :already_accepted)

        _other ->
          Repo.rollback(:invitation_unavailable)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A session revoked (or expired) while the request ran: `401`, never a
  # provider-style `:unauthorized`.
  defp held(:ok), do: :ok
  defp held({:error, :unauthorized}), do: {:error, :session_revoked}

  defp decline_locked(user, locator) do
    case lock_for_recipient(user, locator) do
      {:ok, gym, invitation, addresses} ->
        now = DateTime.utc_now()

        case answered_by(invitation, user, now) do
          :pending ->
            declined = respond!(invitation, now, status: :declined)
            audit_invitation!(gym.id, user.id, :staff_invitation_declined, declined, now)
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
  # gym row and the invitation in the SF-83 order and checks the recipient.
  # By id, only an invitation addressed to the caller is ever loaded.
  defp lock_for_recipient(user, locator) do
    addresses = recipient_addresses(user)

    query =
      case locator do
        {:token, hash} -> from(i in StaffInvitation, where: i.token_hash == ^hash)
        {:id, id} -> mine_query(addresses, id)
      end

    with %StaffInvitation{gym_id: gym_id} <- Repo.one(query, @unlogged),
         %Gym{} = gym <- Access.lock_gym!(gym_id),
         %StaffInvitation{} = invitation <-
           Repo.one(from(i in query, lock: "FOR UPDATE"), @unlogged) do
      if Map.has_key?(addresses, invitation.recipient_digest),
        do: {:ok, gym, invitation, addresses},
        else: recipient_mismatch(invitation)
    else
      nil -> {:error, unknown(locator)}
    end
  end

  # A token held by another account learns only that it is not theirs, and
  # only while the invitation is still usable.
  defp recipient_mismatch(invitation) do
    if StaffInvitation.effective_status(invitation, DateTime.utc_now()) == :pending,
      do: {:error, :invitation_recipient_mismatch},
      else: {:error, :invitation_unavailable}
  end

  defp unknown({:token, _hash}), do: :invitation_unavailable
  defp unknown({:id, _id}), do: :not_found

  # `:pending`, or how this person answered it before (a lost response), or
  # anything else (expired, cancelled, answered by another of their accounts
  # or no longer backed by a membership).
  defp answered_by(invitation, user, now) do
    case StaffInvitation.effective_status(invitation, now) do
      :pending ->
        :pending

      :accepted ->
        case Repo.get(StaffMembership, invitation.staff_membership_id, @unlogged) do
          %StaffMembership{user_id: user_id, status: :active} = membership
          when user_id == user.id ->
            {:accepted, membership}

          _ ->
            :unavailable
        end

      :declined ->
        :declined

      other ->
        other
    end
  end

  defp activate!(user, gym, invitation, addresses, now) do
    with :ok <- registered(user),
         :ok <- inviter_still_allowed(invitation),
         {:ok, membership} <- insert_membership(gym, user, invitation.role, now) do
      accepted = respond!(invitation, now, status: :accepted, staff_membership_id: membership.id)
      audit_invitation!(gym.id, user.id, :staff_invitation_accepted, accepted, now)

      Audit.record!(
        %{
          gym_id: gym.id,
          actor_user_id: user.id,
          event_type: :staff_membership_created,
          staff_membership_id: membership.id,
          staff_invitation_id: accepted.id,
          to_role: membership.role
        },
        now
      )

      acceptance(gym, accepted, membership, addresses, :accepted)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp acceptance(gym, invitation, membership, addresses, outcome) do
    %{
      invitation:
        recipient_view(invitation, addresses, recipient_context([invitation]), DateTime.utc_now()),
      gym_id: gym.id,
      staff_membership_id: membership.id,
      role: membership.role,
      outcome: outcome
    }
  end

  # Accepting needs a completed account (ADR 0016) and nothing else: no
  # Fighter or Coach profile (SF-82 03 §5, D-G06).
  defp registered(user) do
    if Accounts.registration_complete?(user),
      do: :ok,
      else: {:error, prerequisite_error(:account_registration)}
  end

  # Defence in depth: ending or demoting the inviter cancels its pending
  # invitations under the same gym lock, so this only refuses what that
  # rule already resolved.
  defp inviter_still_allowed(invitation) do
    case Repo.get(StaffMembership, invitation.invited_by_staff_membership_id, @unlogged) do
      %StaffMembership{status: :active} = inviter ->
        case Policy.check(inviter, permission_for(invitation.role)) do
          {:ok, _scope} -> :ok
          {:error, :forbidden} -> {:error, :invitation_unavailable}
        end

      _ ->
        {:error, :invitation_unavailable}
    end
  end

  # One active membership per user and gym: the partial unique index decides
  # (an existing one, or a concurrent acceptance of another invitation sent
  # to another of this person's addresses).
  defp insert_membership(gym, user, role, now) do
    {count, rows} =
      Repo.insert_all(
        StaffMembership,
        [
          %{
            id: Ecto.UUID.generate(),
            gym_id: gym.id,
            user_id: user.id,
            role: role,
            status: :active,
            inserted_at: now,
            updated_at: now
          }
        ],
        Keyword.merge(@unlogged,
          on_conflict: :nothing,
          conflict_target: {:unsafe_fragment, "(gym_id, user_id) WHERE status = 'active'"},
          returning: true
        )
      )

    case {count, rows} do
      {1, [membership]} -> {:ok, membership}
      {0, _} -> {:error, {:conflict, %{staff_membership: "already_active"}}}
    end
  end

  ## Creation

  defp insert!(gym, inviter, params, digest, user) do
    now = DateTime.utc_now()
    token = InvitationSecrets.generate_token()

    {1, [invitation]} =
      Repo.insert_all(
        StaffInvitation,
        [
          %{
            id: Ecto.UUID.generate(),
            gym_id: gym.id,
            invited_by_staff_membership_id: inviter.id,
            token_hash: InvitationSecrets.hash!(token),
            recipient_digest: digest,
            recipient_sealed: InvitationSecrets.seal(params.email),
            role: params.role,
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

    audit_invitation!(gym.id, user.id, :staff_invited, invitation, now)
    deliver!(gym, inviter, params.email, token, invitation)
    invitation
  end

  @create_types %{email: :string, role: :string}
  @role_values Enum.map(StaffInvitation.roles(), &Atom.to_string/1)

  defp create_params(attrs, user) do
    changeset =
      {%{}, @create_types}
      |> Changeset.cast(attrs, Map.keys(@create_types))
      |> Changeset.validate_required([:email, :role])
      |> Changeset.validate_inclusion(:role, @role_values)
      |> normalize_email()
      |> not_self(user)
      |> reject_unknown_fields(attrs, ["email", "role"])

    if changeset.valid? do
      params = Changeset.apply_changes(changeset)
      {:ok, %{params | role: String.to_existing_atom(params.role)}}
    else
      {:error, changeset}
    end
  end

  defp normalize_email(changeset) do
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

  # Nobody invites an address of their own (an owner cannot invite themselves
  # into a second, lesser role; acceptance would refuse it anyway).
  defp not_self(%Changeset{valid?: true} = changeset, user) do
    if Changeset.get_change(changeset, :email) in Accounts.verified_email_addresses(user),
      do: Changeset.add_error(changeset, :email, "is your own address"),
      else: changeset
  end

  defp not_self(changeset, _user), do: changeset

  # Any other field (a gym id, a status, a token, an owner role...) is
  # rejected under its own name, without creating atoms or echoing it.
  defp reject_unknown_fields(changeset, attrs, allowed) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a permitted field", []}} | acc.errors], valid?: false}
    end)
  end

  defp completed(%Gym{setup_status: :completed}), do: :ok
  defp completed(%Gym{}), do: {:error, {:conflict, %{setup_status: "draft"}}}

  # A pending invitation past its expiry stops blocking a new one.
  defp expire_stale!(gym_id, digest) do
    now = DateTime.utc_now()

    from(i in StaffInvitation,
      where:
        i.gym_id == ^gym_id and i.recipient_digest == ^digest and i.status == :pending and
          i.expires_at <= ^now
    )
    |> Repo.update_all([set: [status: :expired, updated_at: now]], @unlogged)

    :ok
  end

  defp pending_for(gym_id, digest, role) do
    case Repo.one(
           from(i in StaffInvitation,
             where: i.gym_id == ^gym_id and i.recipient_digest == ^digest and i.status == :pending
           ),
           @unlogged
         ) do
      nil -> {:ok, nil}
      %StaffInvitation{role: ^role} = existing -> {:ok, existing}
      _other -> {:error, {:conflict, %{staff_invitation: "pending_other_role"}}}
    end
  end

  # The gym's administrators may learn that an address belongs to one of
  # their own active staff, nothing else about accounts.
  defp not_staff(gym_id, address) do
    with {:ok, %User{id: user_id}} <- Accounts.resolve_user(:email, address),
         true <-
           Repo.exists?(
             from(m in StaffMembership,
               where: m.gym_id == ^gym_id and m.user_id == ^user_id and m.status == :active
             ),
             @unlogged
           ) do
      {:error, {:conflict, %{staff_membership: "already_active"}}}
    else
      _ -> :ok
    end
  end

  defp permission_for(:manager), do: :invite_manager
  defp permission_for(role) when role in [:coach, :front_desk], do: :invite_staff

  ## Gym-side locks and transitions

  defp lock_of_gym(gym_id, invitation_id) do
    with {:ok, id} <- Access.cast_id(invitation_id) |> found(),
         %StaffInvitation{} = invitation <-
           Repo.one(
             from(i in StaffInvitation,
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
      StaffInvitation.effective_status(invitation, now) != :pending ->
        {:error, {:conflict, %{staff_invitation: "not_pending"}}}

      invitation.send_count >= @max_sends ->
        {:error, {:conflict, %{resends: "limit_reached"}}}

      cooldown > 0 ->
        {:error, {:rate_limited, cooldown}}

      true ->
        {:ok, address} = InvitationSecrets.open(invitation.recipient_sealed)
        token = InvitationSecrets.generate_token()

        {1, [updated]} =
          Repo.update_all(
            from(i in StaffInvitation, where: i.id == ^invitation.id, select: i),
            [
              set: [
                token_hash: InvitationSecrets.hash!(token),
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

  defp cancel!(invitation, actor_user_id, now) do
    cancelled = respond!(invitation, now, status: :cancelled)

    audit_invitation!(
      invitation.gym_id,
      actor_user_id,
      :staff_invitation_cancelled,
      cancelled,
      now
    )

    cancelled
  end

  defp expire!(invitation, now) do
    {1, [expired]} =
      Repo.update_all(
        from(i in StaffInvitation, where: i.id == ^invitation.id, select: i),
        [set: [status: :expired, updated_at: now]],
        @unlogged
      )

    expired
  end

  defp respond!(invitation, now, changes) do
    {1, [updated]} =
      Repo.update_all(
        from(i in StaffInvitation, where: i.id == ^invitation.id, select: i),
        [set: Keyword.merge(changes, responded_at: now, updated_at: now)],
        @unlogged
      )

    updated
  end

  defp audit_invitation!(gym_id, actor_user_id, event_type, invitation, now) do
    Audit.record!(
      %{
        gym_id: gym_id,
        actor_user_id: actor_user_id,
        event_type: event_type,
        staff_invitation_id: invitation.id,
        staff_membership_id: invitation.staff_membership_id,
        to_role: invitation.role
      },
      now
    )
  end

  defp inviter_of(invitation),
    do: Repo.get!(StaffMembership, invitation.invited_by_staff_membership_id, @unlogged)

  ## Email (E06)

  @role_labels %{manager: "Manager", coach: "Coach", front_desk: "Front desk"}

  # What each role can do at a gym today (the SF-82 matrix, limited to what
  # exists): no check-in, class, member or money ability is promised before
  # its domain ships.
  @abilities %{
    manager: [
      "Edit the gym’s details and location",
      "Invite coaches and front-desk staff",
      "See the gym’s team"
    ],
    coach: ["Open the gym’s workspace", "See the gym’s team"],
    front_desk: ["Open the gym’s workspace", "See the gym’s team"]
  }

  # Enqueued in the caller's transaction (an outbox): the job exists exactly
  # when the invitation (or its new token) commits. The job payload is
  # encrypted (ADR 0011); the token travels only in the link's fragment.
  defp deliver!(gym, inviter, address, token, invitation) do
    config = Application.get_env(:simple_fit, SimpleFit.Gyms, [])
    inviter_name = first_name(inviter.user_id)

    rendered =
      Templates.staff_invite(
        inviter_name: inviter_name,
        inviter_display_name: inviter_name,
        inviter_role: inviter.role |> role_label() |> String.downcase(),
        gym_name: gym.name,
        role: role_label(invitation.role),
        permissions: Map.fetch!(@abilities, invitation.role),
        accept_url: "#{config[:web_app_url]}/invite/staff#token=#{token}",
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

  defp role_label(:owner), do: "Owner"
  defp role_label(role), do: Map.fetch!(@role_labels, role)

  defp first_name(nil), do: "A team member"

  defp first_name(user_id) do
    case Accounts.short_names([user_id]) do
      %{^user_id => %{first_name: first}} -> first
      _ -> "A team member"
    end
  end

  ## Views

  # The gym sees the address it typed, masked ("n•••@example.com"), and the
  # inviting staff member's short name; never the token or the digest.
  defp admin_view(invitation),
    do: admin_view(invitation, inviter_names([invitation]), DateTime.utc_now())

  defp admin_view(%StaffInvitation{} = invitation, names, now) do
    status = StaffInvitation.effective_status(invitation, now)

    %{
      invitation_id: invitation.id,
      role: invitation.role,
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
      staff_membership_id: invitation.staff_membership_id
    }
  end

  # Short names of the inviting memberships, by membership id.
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

    Map.new(memberships, fn {id, user_id} ->
      {id, get_in(names, [user_id, :short_name])}
    end)
  end

  # The gym names and inviters' first names an invitation's recipient sees.
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

  defp preview_view(invitation, context) do
    %{
      gym: %{name: Map.get(context.gyms, invitation.gym_id)},
      role: invitation.role,
      invited_by: inviter_projection(invitation, context),
      expires_at: invitation.expires_at
    }
  end

  # The recipient's own view: also the address of theirs it was sent to.
  defp recipient_view(invitation, addresses, context, now) do
    %{
      invitation_id: invitation.id,
      status: StaffInvitation.effective_status(invitation, now),
      role: invitation.role,
      gym: %{gym_id: invitation.gym_id, name: Map.get(context.gyms, invitation.gym_id)},
      invited_by: inviter_projection(invitation, context),
      sent_to: Map.get(addresses, invitation.recipient_digest),
      created_at: invitation.inserted_at,
      expires_at: invitation.expires_at,
      responded_at: invitation.responded_at,
      staff_membership_id: invitation.staff_membership_id
    }
  end

  defp masked(sealed) do
    case InvitationSecrets.open(sealed) do
      {:ok, address} ->
        [local, domain] = String.split(address, "@", parts: 2)
        String.first(local) <> "•••@" <> domain

      :error ->
        "•••"
    end
  end

  ## Recipient helpers

  # Digest => canonical address of every email identity of the user.
  defp recipient_addresses(user) do
    user
    |> Accounts.verified_email_addresses()
    |> Map.new(&{InvitationSecrets.recipient_digest(&1), &1})
  end

  defp mine_query(addresses, id) do
    digests = Map.keys(addresses)
    from(i in StaffInvitation, where: i.id == ^id and i.recipient_digest in ^digests)
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
    case InvitationSecrets.token_hash(token) do
      {:ok, hash} -> {:ok, hash}
      :error -> {:error, :invitation_unavailable}
    end
  end

  defp found({:ok, id}), do: {:ok, id}
  defp found(:error), do: {:error, :not_found}

  defp prerequisite_error(field) do
    {%{}, %{field => :string}}
    |> Changeset.change()
    |> Changeset.add_error(field, "must be completed first", validation: :required)
  end

  ## Limits

  defp create_limits(user, gym, digest, client_ip) do
    RateLimit.hit_rolling([
      {"gym_staff_invite_client", key("client", client_ip), 20, 600},
      {"gym_staff_invite_user_hour", key("user", user.id), 10, 3600},
      {"gym_staff_invite_user_day", key("user", user.id), 30, 86_400},
      {"gym_staff_invite_gym_day", key("gym", gym.id), 100, 86_400},
      {"gym_staff_invite_recipient_day", key("recipient", Base.encode64(digest)), 3, 86_400}
    ])
    |> rate_limited()
  end

  defp response_limit(client_ip) do
    RateLimit.hit([{"gym_staff_invite_response_client", key("client", client_ip), 30, 600}])
    |> rate_limited()
  end

  @doc false
  # Staff administration (resend, cancel, role change, removal): per user.
  @spec admin_limit(User.t()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def admin_limit(%User{id: user_id}) do
    RateLimit.hit([{"gym_staff_admin_user", key("user", user_id), 60, 600}])
    |> rate_limited()
  end

  defp rate_limited(:ok), do: :ok
  defp rate_limited({:error, {:rate_limited, _retry_after}} = error), do: error

  defp key(kind, value), do: InvitationSecrets.rate_limit_key(kind, value)

  ## Paging

  defp list_params(params) do
    types = %{limit: :integer, cursor: :string, status: :string}
    statuses = Enum.map(StaffInvitation.statuses(), &Atom.to_string/1)

    changeset =
      {%{limit: @default_limit, cursor: nil, status: nil}, types}
      |> Changeset.cast(Map.take(params, ["limit", "cursor", "status"]), Map.keys(types))
      |> Changeset.validate_number(:limit,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: @max_limit
      )
      |> Changeset.validate_inclusion(:status, statuses)

    with %Changeset{valid?: true} <- changeset,
         {:ok, position} <- decode_cursor(Changeset.get_field(changeset, :cursor)) do
      status = Changeset.get_field(changeset, :status)

      {:ok,
       %{
         limit: Changeset.get_field(changeset, :limit),
         cursor: position,
         status: status && String.to_existing_atom(status)
       }}
    else
      %Changeset{} = invalid ->
        {:error, invalid}

      :error ->
        {:error, Changeset.add_error(changeset, :cursor, "is invalid", validation: :format)}
    end
  end

  # Filters by the effective status: a stored `pending` past its expiry is
  # `expired`, never both.
  defp with_status(query, nil, _now), do: query

  defp with_status(query, :pending, now),
    do: from(i in query, where: i.status == :pending and i.expires_at > ^now)

  defp with_status(query, :expired, now),
    do:
      from(i in query,
        where: i.status == :expired or (i.status == :pending and i.expires_at <= ^now)
      )

  defp with_status(query, status, _now), do: from(i in query, where: i.status == ^status)

  defp seek(query, nil), do: query

  defp seek(query, {at, id}),
    do: from(i in query, where: i.inserted_at < ^at or (i.inserted_at == ^at and i.id < ^id))

  defp encode_cursor(%StaffInvitation{inserted_at: at, id: id}),
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

  ## Telemetry

  defp outcome({:ok, _}), do: %{outcome: :ok}
  defp outcome({:error, reason}), do: %{outcome: reason_tag(reason)}

  defp reason_tag(%Changeset{}), do: :validation_error
  defp reason_tag({:conflict, _}), do: :conflict
  defp reason_tag({:rate_limited, _}), do: :rate_limited
  defp reason_tag(reason) when is_atom(reason), do: reason

  # Outcomes only: never a token, address, digest or id.
  defp emit(event, metadata),
    do: :telemetry.execute([:simple_fit, :gyms, :staff_invitation, event], %{count: 1}, metadata)
end
