defmodule SimpleFit.Coaching.Invitations do
  @moduledoc """
  Coach invitations and the fighter's explicit acceptance (SF-57; ADR 0021
  amendment; SF-49 §6.3, §7). Internal to `SimpleFit.Coaching`, which
  exposes these operations.

  ## Lifecycle

  `pending` → `accepted` | `declined` | `cancelled` | `expired` (all
  terminal; the database forbids any later change). A pending invitation
  past `expires_at` is expired whatever its stored status says; the stored
  status catches up when the invitation is next touched. An invitation is
  never a relationship: acceptance creates one through the trusted
  `SimpleFit.Coaching.Activation`, in the transaction that consumes the
  invitation.

  ## Recipient binding

  The recipient address is stored as an HMAC digest and a sealed copy. Only
  a signed-in user holding an email identity for that exact address (an
  address they proved with a code, ADR 0012) can accept or decline; holding
  the token is not enough, and no identity is ever linked or created.

  ## Tokens

  One-time `sfi_` tokens, 14 days; only their hash is stored. A resend
  rotates the token on the same invitation: the previous one stops matching
  at once. Unknown, rotated, used, declined, cancelled and expired tokens all
  answer `:invitation_unavailable` (no state oracle).

  ## Gate and prerequisites

  Creating, resending, previewing and accepting need Coach–Fighter sharing
  enabled and a current disclosure version (`SimpleFit.Coaching.Disclosure`);
  creating also needs the coach's acknowledgement of the configured coach
  data-rules version. Until then they answer `:not_found`. Cancelling and
  declining stay available: they never grant access.

  ## Abuse limits (PostgreSQL windows, ADR 0019 conventions)

  Per coach 10/hour and 30/day, per recipient (any coach) 3/day, per client
  20 per 10 minutes for creation; resend after 60 seconds, at most 3 resends
  per invitation; at most 50 pending invitations per coach; preview, accept
  and decline 30 per 10 minutes per client.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.{Accounts, Coaches, Coaching, Email, Fighters, RateLimit, Repo}
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaching.{Activation, DataRulesAcknowledgement, Disclosure}
  alias SimpleFit.Coaching.{Invitation, InvitationSecrets}
  alias SimpleFit.Email.Templates

  @unlogged [log: false]

  @lifetime 14 * 24 * 60 * 60
  @resend_cooldown 60
  @max_sends 4
  @max_pending 50
  @default_limit 50
  @max_limit 100

  @field_labels %{
    display_name: "Display name",
    username: "Username",
    country_code: "Country",
    city: "City",
    experience_level: "Experience level",
    stance: "Stance",
    amateur_bout_count: "Amateur bout count"
  }

  @never_shared ~w(goals next_fight weight height account_name date_of_birth email
                   other_coaches)a

  @type error ::
          :not_found
          | :conflict
          | :invitation_unavailable
          | :invitation_recipient_mismatch
          | {:conflict, map()}
          | {:rate_limited, pos_integer()}
          | Changeset.t()

  @doc "What is never shared with a coach, for the preview (category codes)."
  @spec never_shared() :: [atom()]
  def never_shared, do: @never_shared

  ## Coach data rules

  @doc """
  The configured coach data-rules version and the coach's acknowledgement of
  it. `:not_found` while sharing is disabled or without a completed coach
  profile.
  """
  @spec data_rules(User.t()) ::
          {:ok, %{document_version: String.t() | nil, acknowledged_at: DateTime.t() | nil}}
          | {:error, :not_found}
  def data_rules(%User{} = user) do
    with {:ok, coach} <- coach(user) do
      version = Disclosure.data_rules_version()
      {:ok, %{document_version: version, acknowledged_at: acknowledged_at(coach, version)}}
    end
  end

  @doc """
  Records the coach's acknowledgement of `document_version`, which must be
  the configured coach data-rules version (otherwise `{:conflict,
  %{document_version: "stale"}}`). Idempotent: the first acknowledgement's
  time is kept.
  """
  @spec acknowledge_data_rules(User.t(), map()) ::
          {:ok, %{document_version: String.t(), acknowledged_at: DateTime.t() | nil}}
          | {:error, error()}
  def acknowledge_data_rules(%User{} = user, attrs) when is_map(attrs) do
    with {:ok, coach} <- coach(user),
         {:ok, current} <- configured_data_rules(),
         {:ok, version} <- version_param(attrs, "document_version"),
         :ok <- same_version(version, current, :document_version) do
      {_inserted, _} =
        Repo.insert_all(
          DataRulesAcknowledgement,
          [
            %{
              id: Ecto.UUID.generate(),
              coach_profile_id: coach.id,
              document_version: version,
              acknowledged_at: DateTime.utc_now()
            }
          ],
          Keyword.merge(@unlogged,
            on_conflict: :nothing,
            conflict_target: [:coach_profile_id, :document_version]
          )
        )

      emit(:data_rules_acknowledged, %{})
      {:ok, %{document_version: version, acknowledged_at: acknowledged_at(coach, version)}}
    end
  end

  defp configured_data_rules do
    case Disclosure.data_rules_version() do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  ## Coach side

  @doc """
  Invites `email` to connect (params: `"email"`, optional `"message"`).
  Creates nothing but the invitation and its E08 delivery job, in one
  transaction. A pending invitation of this coach to the same address is
  returned as is (`:existing`: no new token, no email).
  """
  @spec create(User.t(), map(), String.t()) ::
          {:ok, Invitation.t(), :created | :existing} | {:error, error()}
  def create(%User{} = user, attrs, client_ip) when is_map(attrs) and is_binary(client_ip) do
    with {:ok, coach} <- coach(user),
         :ok <- inviting_available(),
         :ok <- data_rules_acknowledged(coach),
         {:ok, params} <- create_params(attrs, user),
         digest = InvitationSecrets.recipient_digest(params.email),
         :ok <- create_limits(coach, digest, client_ip) do
      Repo.transaction(
        fn -> insert_or_existing(coach, params.email, digest, params.message) end,
        @unlogged
      )
      |> case do
        {:ok, {invitation, :created}} ->
          emit(:created, %{outcome: :created})
          {:ok, invitation, :created}

        {:ok, {invitation, :existing}} ->
          emit(:created, %{outcome: :existing})
          {:ok, invitation, :existing}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "The coach's invitations, newest first (params: `limit`, `cursor`)."
  @spec list(User.t(), map()) ::
          {:ok, %{entries: [map()], next_cursor: String.t() | nil}} | {:error, error()}
  def list(%User{} = user, params) when is_map(params) do
    with {:ok, coach} <- coach(user),
         {:ok, %{limit: limit, cursor: cursor}} <- page_params(params) do
      rows =
        from(i in Invitation,
          where: i.coach_profile_id == ^coach.id,
          order_by: [desc: i.inserted_at, desc: i.id],
          limit: ^(limit + 1)
        )
        |> seek(cursor)
        |> Repo.all(@unlogged)

      {rows, rest} = Enum.split(rows, limit)
      now = DateTime.utc_now()

      {:ok,
       %{
         entries: Enum.map(rows, &coach_view(&1, now)),
         next_cursor: if(rest == [], do: nil, else: encode_cursor(List.last(rows)))
       }}
    end
  end

  @doc """
  Sends a pending invitation again with a new token (the previous token
  stops working) and a new 14-day expiry. At most 3 resends, 60 seconds
  apart; only while pending.
  """
  @spec resend(User.t(), String.t(), String.t()) :: {:ok, Invitation.t()} | {:error, error()}
  def resend(%User{} = user, id, client_ip) when is_binary(client_ip) do
    with {:ok, coach} <- coach(user),
         :ok <- inviting_available(),
         {:ok, id} <- uuid(id),
         :ok <- RateLimit.hit([coach_hour_rule(coach)]) |> rate_limited() do
      Repo.transaction(fn -> resend_locked(coach, id) end, @unlogged)
      |> case do
        {:ok, invitation} ->
          emit(:resent, %{})
          {:ok, invitation}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Cancels a pending invitation of the coach. Idempotent for an invitation
  already cancelled or expired; `:conflict` once accepted or declined.
  Available whatever the sharing gate says.
  """
  @spec cancel(User.t(), String.t()) :: :ok | {:error, error()}
  def cancel(%User{} = user, id) do
    with {:ok, coach} <- completed(Coaches.get_profile(user)),
         {:ok, id} <- uuid(id) do
      Repo.transaction(fn -> cancel_locked(coach, id) end, @unlogged)
      |> cancelled()
    end
  end

  defp cancelled({:ok, :cancelled}) do
    emit(:cancelled, %{})
    :ok
  end

  defp cancelled({:ok, :unchanged}), do: :ok
  defp cancelled({:error, reason}), do: {:error, reason}

  ## Recipient side

  @doc """
  What the holder of `token` may see before signing in: the coach's public
  identity, the coach's note, the expiry and the current disclosure. No
  recipient or account information.
  """
  @spec preview(term(), String.t()) :: {:ok, map()} | {:error, error()}
  def preview(token, client_ip) when is_binary(client_ip) do
    with :ok <- inviting_available(),
         :ok <- response_limit(client_ip),
         {:ok, invitation} <- usable(token) do
      coach = Coaches.public_projection([invitation.coach_profile_id])
      version = Disclosure.current()

      {:ok,
       %{
         coach: Map.get(coach, invitation.coach_profile_id),
         message: invitation.message,
         expires_at: invitation.expires_at,
         disclosure: %{
           version: version,
           fields: Disclosure.fields(version),
           never_shared: @never_shared
         }
       }}
    end
  end

  @doc """
  Accepts an invitation: the signed-in recipient (bound by a verified email
  identity), with completed account registration and fighter profile,
  accepting exactly the current disclosure version (`params`: `"token"`,
  `"disclosure_version"`). One transaction locks the invitation, activates
  the relationship through `SimpleFit.Coaching.Activation` and consumes the
  invitation with the accepted version as evidence; anything failing rolls
  everything back. A pair already connected resolves to the existing
  relationship (`:already_connected`), whose accepted disclosure is not
  changed. A consumed token answers `:invitation_unavailable`.
  """
  @spec accept(User.t(), map(), String.t()) ::
          {:ok, %{relationship_id: Ecto.UUID.t(), outcome: :created | :already_connected}}
          | {:error, error()}
  def accept(%User{} = user, params, client_ip) when is_map(params) and is_binary(client_ip) do
    with :ok <- inviting_available(),
         :ok <- response_limit(client_ip),
         {:ok, hash} <- token_param(params),
         {:ok, version} <- version_param(params, "disclosure_version") do
      Repo.transaction(fn -> accept_locked(user, hash, version) end, @unlogged)
      |> case do
        {:ok, result} ->
          emit(:accepted, %{outcome: result.outcome})
          {:ok, result}

        {:error, reason} ->
          emit(:rejected, %{reason: reason_tag(reason)})
          {:error, reason}
      end
    end
  end

  @doc """
  Declines an invitation: the signed-in recipient (bound as for
  `accept/3`) with a completed fighter profile. Creates nothing. Available
  whatever the sharing gate says.
  """
  @spec decline(User.t(), map(), String.t()) :: :ok | {:error, error()}
  def decline(%User{} = user, params, client_ip) when is_map(params) and is_binary(client_ip) do
    with :ok <- response_limit(client_ip),
         {:ok, hash} <- token_param(params) do
      Repo.transaction(fn -> decline_locked(user, hash) end, @unlogged)
      |> case do
        {:ok, :declined} ->
          emit(:declined, %{})
          :ok

        {:error, reason} ->
          emit(:rejected, %{reason: reason_tag(reason)})
          {:error, reason}
      end
    end
  end

  # -- Prerequisites ---------------------------------------------------------

  # Coach operations other than cancel need the sharing gate.
  defp coach(user) do
    if Coaching.access_enabled?(),
      do: completed(Coaches.get_profile(user)),
      else: {:error, :not_found}
  end

  defp completed(%{onboarding_completed_at: %DateTime{}} = profile), do: {:ok, profile}
  defp completed(_profile), do: {:error, :not_found}

  # New sharing needs the gate and a disclosure a fighter can accept now.
  defp inviting_available do
    if Coaching.access_enabled?() and is_binary(Disclosure.current()),
      do: :ok,
      else: {:error, :not_found}
  end

  # No configured data-rules version: inviting is unavailable (nothing to
  # acknowledge). A configured one must have been acknowledged by the coach.
  defp data_rules_acknowledged(coach) do
    case Disclosure.data_rules_version() do
      nil ->
        {:error, :not_found}

      version ->
        if acknowledged_at(coach, version),
          do: :ok,
          else: {:error, {:conflict, %{data_rules_acknowledgement: "required"}}}
    end
  end

  defp acknowledged_at(_coach, nil), do: nil

  defp acknowledged_at(coach, version) do
    Repo.one(
      from(a in DataRulesAcknowledgement,
        where: a.coach_profile_id == ^coach.id and a.document_version == ^version,
        select: a.acknowledged_at
      ),
      @unlogged
    )
  end

  # -- Params ----------------------------------------------------------------

  @create_types %{email: :string, message: :string}

  defp create_params(attrs, user) do
    changeset =
      {%{}, @create_types}
      |> Changeset.cast(attrs, Map.keys(@create_types))
      |> Changeset.validate_required([:email])
      |> normalize_email()
      |> validate_message()
      |> not_self(user)
      |> reject_unknown_fields(attrs)

    if changeset.valid?,
      do: {:ok, Map.put_new(Changeset.apply_changes(changeset), :message, nil)},
      else: {:error, changeset}
  end

  # Any other field (a coach id, a status, an expiry, a token...) is rejected
  # under its own name, without creating atoms or echoing its value.
  defp reject_unknown_fields(changeset, attrs) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in ["email", "message"]))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a permitted field", []}} | acc.errors], valid?: false}
    end)
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

  # One plain-text paragraph (the E08 note), 1..500 characters.
  defp validate_message(changeset) do
    case Changeset.get_change(changeset, :message) do
      nil ->
        changeset

      message ->
        message = String.trim(message)

        cond do
          message == "" ->
            Changeset.put_change(changeset, :message, nil)

          String.length(message) > 500 ->
            Changeset.add_error(changeset, :message, "is too long",
              validation: :length,
              kind: :max,
              count: 500
            )

          String.match?(message, ~r/[\p{Cc}\p{Cf}\x{2028}\x{2029}]/u) ->
            Changeset.add_error(changeset, :message, "is invalid", validation: :format)

          true ->
            Changeset.put_change(changeset, :message, message)
        end
    end
  end

  # A coach cannot invite an address they hold themselves (acceptance also
  # refuses self-coaching, through the relationship invariants).
  defp not_self(%Changeset{valid?: true} = changeset, user) do
    email = Changeset.get_change(changeset, :email)

    if email in Accounts.verified_email_addresses(user),
      do: Changeset.add_error(changeset, :email, "is your own address"),
      else: changeset
  end

  defp not_self(changeset, _user), do: changeset

  defp version_param(params, key) do
    case params[key] do
      version when is_binary(version) and byte_size(version) in 1..64 ->
        {:ok, version}

      _ ->
        types = %{String.to_existing_atom(key) => :string}

        {:error,
         {%{}, types}
         |> Changeset.change()
         |> Changeset.add_error(String.to_existing_atom(key), "is invalid", validation: :required)}
    end
  end

  defp token_param(params) do
    case InvitationSecrets.token_hash(params["token"]) do
      {:ok, hash} -> {:ok, hash}
      :error -> {:error, :invitation_unavailable}
    end
  end

  defp same_version(version, version, _field), do: :ok
  defp same_version(_given, _current, field), do: {:error, {:conflict, %{field => "stale"}}}

  defp uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp uuid(_id), do: {:error, :not_found}

  # -- Limits ----------------------------------------------------------------

  defp coach_hour_rule(coach),
    do: {"coach_invite_coach_hour", key("coach", coach.id), 10, 3600}

  defp create_limits(coach, digest, client_ip) do
    RateLimit.hit([
      {"coach_invite_client", key("client", client_ip), 20, 600},
      coach_hour_rule(coach),
      {"coach_invite_coach_day", key("coach", coach.id), 30, 86_400},
      {"coach_invite_recipient_day", key("recipient", Base.encode64(digest)), 3, 86_400}
    ])
    |> rate_limited()
  end

  defp response_limit(client_ip) do
    RateLimit.hit([{"coach_invite_response_client", key("client", client_ip), 30, 600}])
    |> rate_limited()
  end

  defp rate_limited(:ok), do: :ok

  defp rate_limited({:error, {:rate_limited, retry_after}}) do
    emit(:rate_limited, %{})
    {:error, {:rate_limited, retry_after}}
  end

  defp key(kind, value), do: InvitationSecrets.rate_limit_key(kind, value)

  # -- Transactions ----------------------------------------------------------

  defp insert_or_existing(coach, email, digest, message) do
    now = DateTime.utc_now()

    # A pending invitation past its expiry stops blocking a new one.
    from(i in Invitation,
      where:
        i.coach_profile_id == ^coach.id and i.recipient_digest == ^digest and
          i.status == :pending and i.expires_at <= ^now
    )
    |> Repo.update_all([set: [status: :expired, updated_at: now]], @unlogged)

    token = InvitationSecrets.generate_token()

    {inserted, _} =
      Repo.insert_all(
        Invitation,
        [
          %{
            id: Ecto.UUID.generate(),
            coach_profile_id: coach.id,
            token_hash: InvitationSecrets.hash!(token),
            recipient_digest: digest,
            recipient_sealed: InvitationSecrets.seal(email),
            message: message,
            status: :pending,
            expires_at: DateTime.add(now, @lifetime),
            send_count: 1,
            last_sent_at: now,
            inserted_at: now,
            updated_at: now
          }
        ],
        Keyword.merge(@unlogged,
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment, "(coach_profile_id, recipient_digest) WHERE status = 'pending'"}
        )
      )

    invitation =
      Repo.one!(
        from(i in Invitation,
          where:
            i.coach_profile_id == ^coach.id and i.recipient_digest == ^digest and
              i.status == :pending
        ),
        @unlogged
      )

    if inserted == 1 do
      if pending_count(coach) > @max_pending,
        do: Repo.rollback({:conflict, %{pending_invitations: "limit_reached"}})

      deliver!(coach, email, token, invitation)
      {invitation, :created}
    else
      {invitation, :existing}
    end
  end

  defp pending_count(coach) do
    now = DateTime.utc_now()

    Repo.aggregate(
      from(i in Invitation,
        where: i.coach_profile_id == ^coach.id and i.status == :pending and i.expires_at > ^now
      ),
      :count,
      @unlogged
    )
  end

  defp resend_locked(coach, id) do
    now = DateTime.utc_now()

    invitation =
      Repo.one(
        from(i in Invitation,
          where: i.id == ^id and i.coach_profile_id == ^coach.id,
          lock: "FOR UPDATE"
        ),
        @unlogged
      ) || Repo.rollback(:not_found)

    cooldown = @resend_cooldown - DateTime.diff(now, invitation.last_sent_at)

    cond do
      Invitation.effective_status(invitation, now) != :pending ->
        Repo.rollback(:conflict)

      invitation.send_count >= @max_sends ->
        Repo.rollback({:conflict, %{resends: "limit_reached"}})

      cooldown > 0 ->
        Repo.rollback({:rate_limited, cooldown})

      true ->
        {:ok, email} = InvitationSecrets.open(invitation.recipient_sealed)
        token = InvitationSecrets.generate_token()

        {1, [updated]} =
          Repo.update_all(
            from(i in Invitation, where: i.id == ^invitation.id, select: i),
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

        deliver!(coach, email, token, updated)
        updated
    end
  end

  defp cancel_locked(coach, id) do
    now = DateTime.utc_now()

    invitation =
      Repo.one(
        from(i in Invitation,
          where: i.id == ^id and i.coach_profile_id == ^coach.id,
          lock: "FOR UPDATE"
        ),
        @unlogged
      ) || Repo.rollback(:not_found)

    case Invitation.effective_status(invitation, now) do
      :pending ->
        resolve!(invitation, set: [status: :cancelled, responded_at: now, updated_at: now])
        :cancelled

      :expired ->
        if invitation.status == :pending,
          do: resolve!(invitation, set: [status: :expired, updated_at: now])

        :unchanged

      :cancelled ->
        :unchanged

      _accepted_or_declined ->
        Repo.rollback(:conflict)
    end
  end

  # Locks the invitation, then checks it in an order that leaks nothing to a
  # token holder who is not the recipient beyond "this token is unusable".
  defp locked_for_recipient(user, hash) do
    now = DateTime.utc_now()

    invitation =
      Repo.one(
        from(i in Invitation, where: i.token_hash == ^hash, lock: "FOR UPDATE"),
        @unlogged
      )

    cond do
      is_nil(invitation) or Invitation.effective_status(invitation, now) != :pending ->
        Repo.rollback(:invitation_unavailable)

      invitation.recipient_digest not in recipient_digests(user) ->
        Repo.rollback(:invitation_recipient_mismatch)

      true ->
        {invitation, now}
    end
  end

  defp recipient_digests(user),
    do:
      user
      |> Accounts.verified_email_addresses()
      |> Enum.map(&InvitationSecrets.recipient_digest/1)

  defp accept_locked(user, hash, version) do
    {invitation, now} = locked_for_recipient(user, hash)
    require_fighter!(user)

    case same_version(version, Disclosure.current(), :disclosure_version) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    case Activation.activate(invitation.coach_profile_id, user, version) do
      {:ok, relationship, outcome} ->
        resolve!(invitation,
          set: [
            status: :accepted,
            responded_at: now,
            accepted_disclosure_version: version,
            relationship_id: relationship.id,
            updated_at: now
          ]
        )

        %{
          relationship_id: relationship.id,
          outcome: if(outcome == :created, do: :created, else: :already_connected)
        }

      {:error, :sharing_disabled} ->
        Repo.rollback(:not_found)

      {:error, :disclosure_not_offered} ->
        Repo.rollback({:conflict, %{disclosure_version: "stale"}})

      {:error, :fighter_not_completed} ->
        Repo.rollback(prerequisite_error(:fighter_profile))

      # A coach accepting their own invitation, or a coach profile gone.
      {:error, reason} when reason in [:self_coaching, :coach_unavailable] ->
        Repo.rollback(:invitation_unavailable)
    end
  end

  defp decline_locked(user, hash) do
    {invitation, now} = locked_for_recipient(user, hash)
    require_fighter!(user)
    resolve!(invitation, set: [status: :declined, responded_at: now, updated_at: now])
    :declined
  end

  # Account registration first (ADR 0016), then the fighter profile.
  defp require_fighter!(user) do
    cond do
      not Accounts.registration_complete?(user) ->
        Repo.rollback(prerequisite_error(:account_registration))

      not match?({:ok, _}, completed(Fighters.get_profile(user))) ->
        Repo.rollback(prerequisite_error(:fighter_profile))

      true ->
        :ok
    end
  end

  defp prerequisite_error(field) do
    {%{}, %{field => :string}}
    |> Changeset.change()
    |> Changeset.add_error(field, "must be completed first", validation: :required)
  end

  defp resolve!(invitation, changes) do
    {1, _} =
      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id), changes, @unlogged)

    :ok
  end

  defp usable(token) do
    with {:ok, hash} <- token_param(%{"token" => token}),
         %Invitation{} = invitation <-
           Repo.one(from(i in Invitation, where: i.token_hash == ^hash), @unlogged),
         :pending <- Invitation.effective_status(invitation, DateTime.utc_now()) do
      {:ok, invitation}
    else
      _ -> {:error, :invitation_unavailable}
    end
  end

  # -- Email -----------------------------------------------------------------

  # Enqueued in the caller's transaction (an outbox): the job exists exactly
  # when the invitation (or its new token) is committed. The job payload is
  # encrypted (ADR 0011); the token is never logged.
  defp deliver!(coach, email, token, invitation) do
    config = Application.get_env(:simple_fit, __MODULE__, [])
    profile = Coaches.public_projection([coach.id]) |> Map.fetch!(coach.id)
    name = profile.display_name

    rendered =
      Templates.coach_invite(
        coach_name: name,
        coach_initials: initials(name),
        coaching_name: profile.brand_name || name,
        shared_fields: Enum.map(Disclosure.current_fields(), &Map.fetch!(@field_labels, &1)),
        expires_on: DateTime.to_date(invitation.expires_at),
        message: invitation.message,
        review_url: "#{config[:web_app_url]}/invite/coach#token=#{token}"
      )

    with {:ok, rendered} <- rendered,
         {:ok, message} <- Templates.to_message(rendered, to: email),
         {:ok, _job} <- Email.deliver_later(message) do
      :ok
    else
      {:error, _reason} -> Repo.rollback(:service_unavailable)
    end
  end

  defp initials(name) do
    name
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase(String.first(&1)))
    |> String.replace(~r/[^\p{Lu}]/u, "")
    |> case do
      "" -> "C"
      letters -> letters
    end
  end

  # -- Projections and paging ------------------------------------------------

  @doc "An invitation as its coach sees it (masked recipient, effective status)."
  @spec coach_view(Invitation.t(), DateTime.t()) :: map()
  def coach_view(%Invitation{} = invitation, now \\ DateTime.utc_now()) do
    status = Invitation.effective_status(invitation, now)

    %{
      invitation_id: invitation.id,
      status: status,
      recipient_email: masked(invitation.recipient_sealed),
      message: invitation.message,
      created_at: invitation.inserted_at,
      expires_at: invitation.expires_at,
      last_sent_at: invitation.last_sent_at,
      resends_remaining:
        if(status == :pending, do: max(@max_sends - invitation.send_count, 0), else: 0),
      responded_at: invitation.responded_at
    }
  end

  # The coach sees the address they typed, masked: "a•••@example.com".
  defp masked(sealed) do
    case InvitationSecrets.open(sealed) do
      {:ok, address} ->
        [local, domain] = String.split(address, "@", parts: 2)
        String.first(local) <> "•••@" <> domain

      :error ->
        "•••"
    end
  end

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
         cursor = Changeset.get_field(changeset, :cursor),
         {:ok, position} <- decode_cursor(cursor) do
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
    do: from(i in query, where: i.inserted_at < ^at or (i.inserted_at == ^at and i.id < ^id))

  defp encode_cursor(%Invitation{inserted_at: at, id: id}),
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

  # -- Telemetry -------------------------------------------------------------

  defp reason_tag(%Changeset{}), do: :prerequisite
  defp reason_tag({:conflict, _}), do: :conflict
  defp reason_tag({:rate_limited, _}), do: :rate_limited
  defp reason_tag(reason) when is_atom(reason), do: reason

  # Outcomes only: never a token, address, digest or id.
  defp emit(event, metadata),
    do: :telemetry.execute([:simple_fit, :coaching, :invitation, event], %{count: 1}, metadata)
end
