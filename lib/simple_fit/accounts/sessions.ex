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

  One `UPDATE ... WHERE token_hash = $1 AND consumed_at IS NULL AND
  expires_at > now RETURNING session_id` consumes the token; PostgreSQL's row
  lock makes concurrent attempts wait and then see it consumed, so exactly
  one wins. In the same transaction the session row is locked, checked
  (not revoked, not expired) and a successor token is inserted; a partial
  unique index allows at most one live token per session.

  A consumed token presented again, at any time, is a **reuse**: its session
  is revoked (`refresh_reuse`), which kills the whole token family including
  the successor and every access token of the session. There is no grace
  window: the server cannot tell a client's duplicate request from a replay,
  so clients must serialize their refreshes. A concurrent refresh that loses
  the race is therefore a reuse too.

  Every failure is the same `{:error, :unauthorized}`.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.{RefreshToken, Session, User}
  alias SimpleFit.Repo

  @access_prefix "sfa_"
  @refresh_prefix "sfr_"
  @access_salt "simplefit access token v1"
  @refresh_bytes 32
  @refresh_format ~r/\Asfr_[A-Za-z0-9_-]{43}\z/
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
          secret_key_base: String.t()
        }
  def config! do
    opts = Application.get_env(:simple_fit, __MODULE__, [])
    access = positive!(opts, :access_token_ttl)
    refresh = positive!(opts, :refresh_token_ttl)
    lifetime = positive!(opts, :session_lifetime)

    unless access < refresh and refresh <= lifetime do
      raise ArgumentError,
            "#{inspect(__MODULE__)}: expected access_token_ttl < refresh_token_ttl <= session_lifetime"
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
  same session. Invalid, expired, revoked and reused tokens are all
  `{:error, :unauthorized}`; a reuse also revokes the session.
  """
  @spec refresh(String.t()) :: {:ok, credentials()} | {:error, :unauthorized}
  def refresh(refresh_token) do
    with {:ok, hash} <- refresh_hash(refresh_token) do
      refresh_hashed(hash, config!(), now())
    end
  end

  defp refresh_hashed(hash, config, now) do
    case Repo.transaction(fn -> rotate(hash, now, config) end) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, :not_consumable} -> handle_unusable(hash)
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp rotate(hash, now, config) do
    consume =
      from t in RefreshToken,
        where: t.token_hash == ^hash and is_nil(t.consumed_at) and t.expires_at > ^now,
        select: t.session_id

    with {1, [session_id]} <- Repo.update_all(consume, [set: [consumed_at: now]], @secret_query),
         %Session{} = session <- lock_active_session(session_id, now) do
      issue(session, now, config)
    else
      {0, []} -> Repo.rollback(:not_consumable)
      nil -> Repo.rollback(:unauthorized)
    end
  end

  defp lock_active_session(session_id, now) do
    Repo.one(
      from s in Session,
        where: s.id == ^session_id and is_nil(s.revoked_at) and s.expires_at > ^now,
        lock: "FOR UPDATE"
    )
  end

  # Not consumable: unknown, expired, or already consumed. A consumed token is
  # a reuse, whenever it is presented: the session is revoked.
  defp handle_unusable(hash) do
    case Repo.get_by(RefreshToken, [token_hash: hash], @secret_query) do
      %RefreshToken{consumed_at: %DateTime{}, session_id: session_id} ->
        :ok = revoke_session(session_id, :refresh_reuse)
        {:error, :unauthorized}

      _unknown_or_expired ->
        {:error, :unauthorized}
    end
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

  defp issue(%Session{} = session, now, config) do
    {refresh_token, hash} = new_refresh_token()
    refresh_expires_at = earliest(DateTime.add(now, config.refresh_token_ttl), session.expires_at)

    Repo.insert!(
      %RefreshToken{session_id: session.id, token_hash: hash, expires_at: refresh_expires_at},
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
