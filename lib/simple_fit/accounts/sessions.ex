defmodule SimpleFit.Accounts.Sessions do
  @moduledoc """
  Session lifecycle: issue, authenticate, refresh (rotate), revoke (ADR 0010).

  Called through `SimpleFit.Accounts`; this module is internal to the context.

  ## Credentials

    * **Access token** `sfa_<signed>`: `Plug.Crypto.sign/4` (HMAC-SHA256, key
      derived from `SECRET_KEY_BASE` with a dedicated salt) over the session
      id, valid for `access_token_ttl` seconds. Signed, not encrypted: it
      carries only the session id. Every request re-checks the session, so a
      revoked session stops working immediately.
    * **Refresh token** `sfr_<43 base64url chars>`: 32 random bytes from
      `:crypto.strong_rand_bytes/1`. Only its SHA-256 is stored and looked up
      through a unique index, so no stored value can be replayed and no
      comparison leaks timing about the secret. Single use.

  ## Refresh

  Every refresh decides under the session row lock (`SELECT … FOR UPDATE`),
  so all refreshes and logouts of one session are serialized by PostgreSQL
  on any node. A live token is consumed and a child (`parent_id`) issued; a
  partial unique index allows at most one live token per session.

  A consumed token presented again is a **reuse** that revokes the session
  (`refresh_reuse`), killing the whole token family and every access token,
  unless it is a **lost-response recovery** (SF-75): its child is still the
  session's live token (so no child was ever presented: the response that
  carried it may never have arrived), it was not superseded itself, it was
  consumed at most `refresh_recovery_window` seconds ago and has fewer than
  `refresh_recovery_limit` recoveries. A recovery supersedes that unused
  child and issues a new one; the superseded child is reuse if it ever comes
  back. Two holders of one token therefore always collide: detection is
  delayed by at most one refresh, never lost. ADR 0010, "Reuse".

  Every failure is the same `{:error, :unauthorized}`.

  ## Observability (SF-29)

  Each refresh emits `[:simple_fit, :auth, :session, :refresh]` with an
  `outcome` of `:rotated`, `:recovered`, `:rejected` or `:reuse`, never a
  token, hash, session or user id. A recovery is logged at info: it measures
  how often responses are lost (navigation, app kills). A reuse is logged as
  a warning: it is the signature of a stolen or replayed refresh token (or of
  a client that does not serialize its refreshes), worth watching as a rate,
  not paging on.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias SimpleFit.Accounts.{RefreshToken, Session, User}
  alias SimpleFit.Repo

  @access_prefix "sfa_"
  @refresh_prefix "sfr_"
  @access_salt "simplefit access token v1"
  @refresh_bytes 32
  @refresh_format ~r/\Asfr_[A-Za-z0-9_-]{43}\z/
  # The `recoveries_bounded` check constraint of `session_refresh_tokens`.
  @max_recovery_limit 100
  # Queries that carry a refresh token hash are never logged: Ecto's debug
  # query log would otherwise print the verifier as a parameter.
  @secret_query [log: false]

  @typedoc "Credentials returned when a session is created or refreshed."
  @type credentials :: %{
          session: Session.t(),
          access_token: String.t(),
          access_token_expires_at: DateTime.t(),
          refresh_token: String.t(),
          refresh_token_expires_at: DateTime.t()
        }

  @typedoc "The authenticated viewer of a request."
  @type viewer :: %{user: User.t(), session: Session.t()}

  ## Configuration

  @doc """
  The session policy (`config :simple_fit, SimpleFit.Accounts.Sessions`),
  validated. Raises when it is missing or inconsistent, so a deployment fails
  at boot instead of issuing weak credentials.
  """
  @spec config!() :: %{
          access_token_ttl: pos_integer(),
          refresh_token_ttl: pos_integer(),
          session_lifetime: pos_integer(),
          refresh_recovery_window: pos_integer(),
          refresh_recovery_limit: pos_integer(),
          secret_key_base: String.t()
        }
  def config! do
    opts = Application.get_env(:simple_fit, __MODULE__, [])
    access = positive!(opts, :access_token_ttl)
    refresh = positive!(opts, :refresh_token_ttl)
    lifetime = positive!(opts, :session_lifetime)
    recovery_window = positive!(opts, :refresh_recovery_window)
    recovery_limit = positive!(opts, :refresh_recovery_limit)

    unless access < refresh and refresh <= lifetime do
      raise ArgumentError,
            "#{inspect(__MODULE__)}: expected access_token_ttl < refresh_token_ttl <= session_lifetime"
    end

    # Recovery is for a response lost in transit, not a grace period: it
    # stays well below an access token's lifetime, and the count within the
    # database bound.
    unless recovery_window < access and recovery_limit <= @max_recovery_limit do
      raise ArgumentError,
            "#{inspect(__MODULE__)}: expected refresh_recovery_window < access_token_ttl " <>
              "and refresh_recovery_limit <= #{@max_recovery_limit}"
    end

    secret = opts[:secret_key_base]

    unless is_binary(secret) and byte_size(secret) >= 64 do
      raise ArgumentError,
            "#{inspect(__MODULE__)}: secret_key_base must be at least 64 bytes (SECRET_KEY_BASE)"
    end

    %{
      access_token_ttl: access,
      refresh_token_ttl: refresh,
      session_lifetime: lifetime,
      refresh_recovery_window: recovery_window,
      refresh_recovery_limit: recovery_limit,
      secret_key_base: secret
    }
  end

  defp positive!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 ->
        value

      _other ->
        raise ArgumentError, "#{inspect(__MODULE__)}: #{key} must be a positive integer (seconds)"
    end
  end

  ## Issue

  @doc "Creates a session for `user` and issues its first credentials."
  @spec create(User.t()) :: {:ok, credentials()} | {:error, :not_found}
  def create(%User{id: user_id}) when is_binary(user_id) do
    config = config!()
    now = now()

    Repo.transaction(fn ->
      session =
        %Session{user_id: user_id, expires_at: DateTime.add(now, config.session_lifetime)}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:user_id)
        |> Repo.insert()
        |> case do
          {:ok, session} -> session
          {:error, _changeset} -> Repo.rollback(:not_found)
        end

      issue(session, now, config)
    end)
  end

  ## Authenticate

  @doc "Resolves the viewer for an access token, or `:unauthorized`."
  @spec authenticate(String.t()) :: {:ok, viewer()} | {:error, :unauthorized}
  def authenticate(access_token) do
    now = now()

    with {:ok, session_id} <- verify_access_token(access_token) do
      query =
        from s in Session,
          join: u in assoc(s, :user),
          where: s.id == ^session_id and is_nil(s.revoked_at) and s.expires_at > ^now,
          select: {s, u}

      case Repo.one(query) do
        {session, user} -> {:ok, %{user: user, session: session}}
        nil -> {:error, :unauthorized}
      end
    end
  end

  ## Refresh

  @doc """
  Rotates a refresh token: consumes it and issues new credentials for the
  same session. A consumed token presented again before any of its children
  was presented is a lost-response recovery (SF-75), within the configured
  window and limit. Invalid, expired, revoked and reused tokens are all
  `{:error, :unauthorized}`; a reuse also revokes the session.
  """
  @spec refresh(String.t()) :: {:ok, credentials()} | {:error, :unauthorized}
  def refresh(refresh_token) do
    case refresh_hash(refresh_token) do
      {:ok, hash} ->
        refresh_hashed(hash, config!(), now())

      {:error, :unauthorized} ->
        emit_refresh(:rejected)
        {:error, :unauthorized}
    end
  end

  defp refresh_hashed(hash, config, now) do
    {:ok, result} = Repo.transaction(fn -> rotate(hash, now, config) end)

    case result do
      {:rotated, credentials} ->
        emit_refresh(:rotated)
        {:ok, credentials}

      {:recovered, credentials} ->
        Logger.info("refresh token recovery: unused successor superseded",
          reason: :lost_response
        )

        emit_refresh(:recovered)
        {:ok, credentials}

      :reuse ->
        Logger.warning("refresh token reuse: session revoked", reason: :refresh_reuse)
        emit_refresh(:reuse)
        {:error, :unauthorized}

      :rejected ->
        emit_refresh(:rejected)
        {:error, :unauthorized}
    end
  end

  defp emit_refresh(outcome),
    do:
      :telemetry.execute([:simple_fit, :auth, :session, :refresh], %{count: 1}, %{
        outcome: outcome
      })

  # Every decision is taken under the session row lock, so all refreshes,
  # recoveries and logouts of one session are serialized by PostgreSQL,
  # whichever node or connection they run on. The token is read again under
  # the lock: a concurrent request may have consumed it while this one waited.
  defp rotate(hash, now, config) do
    with %RefreshToken{session_id: session_id} <- token_by_hash(hash),
         %Session{} = session <- lock_session(session_id),
         true <- active?(session, now) do
      decide(token_by_hash(hash), session, now, config)
    else
      _unknown_or_inactive -> :rejected
    end
  end

  # A live token rotates; an expired one is rejected without consequence.
  defp decide(%RefreshToken{consumed_at: nil} = token, session, now, config) do
    if DateTime.after?(token.expires_at, now) do
      :ok = consume!(token, now)
      {:rotated, issue(session, now, config, token.id)}
    else
      :rejected
    end
  end

  # A consumed token: a lost-response recovery when the protocol allows it,
  # reuse otherwise.
  defp decide(%RefreshToken{} = token, session, now, config) do
    live = live_token(session.id)

    if recoverable?(token, live, now, config) do
      :ok = supersede!(live, now)
      :ok = count_recovery!(token)
      {:recovered, issue(session, now, config, token.id)}
    else
      :ok = revoke_session(session.id, :refresh_reuse)
      :reuse
    end
  end

  # Recoverable only while the token is the one its session presented last:
  # its child is the session's live token (no child was ever presented, so
  # the response that carried it may never have arrived), it was not itself
  # superseded, and within the window and the limit.
  defp recoverable?(%RefreshToken{} = token, %RefreshToken{} = live, now, config) do
    is_nil(token.superseded_at) and live.parent_id == token.id and
      DateTime.after?(token.expires_at, now) and
      DateTime.diff(now, token.consumed_at) <= config.refresh_recovery_window and
      token.recoveries < config.refresh_recovery_limit
  end

  defp recoverable?(_token, nil, _now, _config), do: false

  defp token_by_hash(hash), do: Repo.get_by(RefreshToken, [token_hash: hash], @secret_query)

  defp lock_session(session_id),
    do: Repo.one(from(s in Session, where: s.id == ^session_id, lock: "FOR UPDATE"))

  defp active?(%Session{revoked_at: nil, expires_at: expires_at}, now),
    do: DateTime.after?(expires_at, now)

  defp active?(%Session{}, _now), do: false

  defp live_token(session_id),
    do:
      Repo.one(
        from(t in RefreshToken, where: t.session_id == ^session_id and is_nil(t.consumed_at)),
        @secret_query
      )

  defp consume!(%RefreshToken{id: id}, now) do
    {1, _rows} =
      Repo.update_all(from(t in RefreshToken, where: t.id == ^id and is_nil(t.consumed_at)),
        set: [consumed_at: now]
      )

    :ok
  end

  defp supersede!(%RefreshToken{id: id}, now) do
    {1, _rows} =
      Repo.update_all(from(t in RefreshToken, where: t.id == ^id and is_nil(t.consumed_at)),
        set: [consumed_at: now, superseded_at: now]
      )

    :ok
  end

  defp count_recovery!(%RefreshToken{id: id}) do
    {1, _rows} =
      Repo.update_all(from(t in RefreshToken, where: t.id == ^id), inc: [recoveries: 1])

    :ok
  end

  ## Revoke

  @doc """
  Revokes the session behind a credential (logout). Accepts an access token
  or a refresh token (current or consumed). Always `:ok`: logging out an
  unknown or already revoked session is not an error and reveals nothing.
  """
  @spec revoke_by_credential({:access, String.t()} | {:refresh, String.t()}) :: :ok
  def revoke_by_credential(credential) do
    case session_of(credential) do
      {:ok, session_id} -> revoke_session(session_id, :logout)
      :none -> :ok
    end
  end

  defp session_of({:access, token}) do
    case verify_access_token(token) do
      {:ok, session_id} -> {:ok, session_id}
      {:error, :unauthorized} -> :none
    end
  end

  defp session_of({:refresh, token}) do
    with {:ok, hash} <- refresh_hash(token),
         %RefreshToken{session_id: session_id} <-
           Repo.get_by(RefreshToken, [token_hash: hash], @secret_query) do
      {:ok, session_id}
    else
      _unknown -> :none
    end
  end

  @doc """
  Inside the caller's transaction, holds the user's session still active
  until the transaction ends: `:ok`, or `{:error, :unauthorized}` when it was
  revoked, expired or is not the user's. The user row is locked first
  (`FOR KEY SHARE`), then the session (`FOR SHARE`), the order in which a
  user deletion locks them; a logout or refresh reuse (which update the
  session row) commits before, and this answers `:unauthorized`, or waits
  for the caller (SF-93: a staff invitation acceptance commits only on a
  session that is active when it commits).
  """
  @spec hold_active(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :unauthorized}
  def hold_active(user_id, session_id) when is_binary(user_id) and is_binary(session_id) do
    true = Repo.in_transaction?()

    with %User{} <- Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR KEY SHARE")),
         %Session{} = session <-
           Repo.one(
             from(s in Session,
               where: s.id == ^session_id and s.user_id == ^user_id,
               lock: "FOR SHARE"
             )
           ),
         true <- active?(session, now()) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Revokes a session (idempotent: an already revoked session keeps its first reason)."
  @spec revoke_session(Ecto.UUID.t(), Session.revoked_reason()) :: :ok
  def revoke_session(session_id, reason) when reason in [:logout, :refresh_reuse] do
    {_count, _rows} =
      Repo.update_all(
        from(s in Session, where: s.id == ^session_id and is_nil(s.revoked_at)),
        set: [revoked_at: now(), revoked_reason: reason, updated_at: now()]
      )

    :ok
  end

  ## Credentials

  defp issue(%Session{} = session, now, config, parent_id \\ nil) do
    {refresh_token, hash} = new_refresh_token()
    refresh_expires_at = earliest(DateTime.add(now, config.refresh_token_ttl), session.expires_at)

    Repo.insert!(
      %RefreshToken{
        session_id: session.id,
        parent_id: parent_id,
        token_hash: hash,
        expires_at: refresh_expires_at
      },
      @secret_query
    )

    access_expires_at = earliest(DateTime.add(now, config.access_token_ttl), session.expires_at)

    %{
      session: session,
      access_token: sign_access_token(session.id, now, config),
      access_token_expires_at: access_expires_at,
      refresh_token: refresh_token,
      refresh_token_expires_at: refresh_expires_at
    }
  end

  defp sign_access_token(session_id, now, config) do
    @access_prefix <>
      Plug.Crypto.sign(config.secret_key_base, @access_salt, session_id,
        signed_at: DateTime.to_unix(now),
        max_age: config.access_token_ttl
      )
  end

  @doc false
  # Verifies the signature and age of an access token. Exposed for tests that
  # sign tokens in the past.
  @spec verify_access_token(term()) :: {:ok, Ecto.UUID.t()} | {:error, :unauthorized}
  def verify_access_token(@access_prefix <> signed) do
    config = config!()

    with {:ok, session_id} <-
           Plug.Crypto.verify(config.secret_key_base, @access_salt, signed,
             max_age: config.access_token_ttl
           ),
         {:ok, session_id} <- Ecto.UUID.cast(session_id) do
      {:ok, session_id}
    else
      _invalid -> {:error, :unauthorized}
    end
  end

  def verify_access_token(_token), do: {:error, :unauthorized}

  @doc false
  # Signs an access token at an arbitrary time (tests only).
  @spec sign_access_token_at(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def sign_access_token_at(session_id, signed_at),
    do: sign_access_token(session_id, signed_at, config!())

  defp new_refresh_token do
    secret = :crypto.strong_rand_bytes(@refresh_bytes)
    token = @refresh_prefix <> Base.url_encode64(secret, padding: false)
    {token, hash(token)}
  end

  defp refresh_hash(token) when is_binary(token) do
    if Regex.match?(@refresh_format, token), do: {:ok, hash(token)}, else: {:error, :unauthorized}
  end

  defp refresh_hash(_token), do: {:error, :unauthorized}

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp now, do: DateTime.utc_now(:second)
end
