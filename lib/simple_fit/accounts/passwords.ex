defmodule SimpleFit.Accounts.Passwords do
  @moduledoc """
  The optional password credential (SF-157; ADR 0012 and ADR 0028 amendments).
  Called through `SimpleFit.Accounts`; internal to the context.

  A password belongs to the one global user (ADR 0009) and signs in through one of
  that user's **email identities**: the address names the user, the password proves
  it. Nothing else changes about the user: signing in never creates a user, an
  identity, an operator or a permission, and Google, Apple and email-code sign-in
  keep working beside it.

    * **Set or reset** - only with a 6-digit code sent to an email identity's address
      (`EmailAuth` purpose `password_reset`), so a password is never established
      without proof of the mailbox. The new password replaces any previous one and
      every session of the user is revoked (`password_changed`); nobody is signed in.
    * **Change** - in a signed-in session, with the current password. Every other
      session of the user is revoked; this one stays.
    * **Sign in** - email and password start an SF-20 session. A wrong password, an
      unknown address and an account without a password all answer
      `invalid_credentials` after the same Argon2 work, so the answer doesn't reveal
      whether an account or a password exists. Attempts are limited per client and per
      address.

  Passwords are hashed with Argon2id (`argon2_elixir`), never stored, logged or
  returned. Set, change and reset are recorded as append-only security events.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.{EmailAddress, EmailAuth, Identity, PasswordCredential}
  alias SimpleFit.Accounts.EmailAuth.Secrets
  alias SimpleFit.Accounts.{SecurityEvent, Session, Sessions, User}
  alias SimpleFit.{RateLimit, Repo}

  @quiet [log: false]

  @min_length 12
  @max_length 128

  @sign_in_ip {"password_sign_in:ip", 30, 600}
  @sign_in_target [{"minute", 5, 60}, {"hour", 20, 3_600}]
  @change_user {"password_change:user", 10, 3_600}

  @type error ::
          {:error, Ecto.Changeset.t()}
          | {:error, {:rate_limited, pos_integer()}}
          | {:error, :invalid_credentials | :password_not_set | :account_suspended | :conflict}
          | {:error, :code_invalid | :code_expired | :unauthorized}

  @doc "The shortest and longest password accepted, in characters."
  @spec length_range() :: Range.t()
  def length_range, do: @min_length..@max_length

  ## Sign-in

  @doc "Signs in with an email identity's address and the user's password."
  @spec sign_in(term(), term(), String.t()) :: {:ok, Sessions.credentials()} | error()
  def sign_in(email, password, client_ip) do
    with {:ok, params} <- required(%{email: email, password: password}, [:email, :password]),
         %{email: email, password: password} = params,
         {:ok, email} <- normalize(email),
         :ok <- limit([ip_rule(@sign_in_ip, client_ip) | target_rules(email)]) do
      verify(credential_of(email), password)
    end
  end

  defp verify({user, credential}, password) when byte_size(password) <= 4 * @max_length do
    if Argon2.verify_pass(password, credential.password_hash),
      do: start_session(user),
      else: refuse(:sign_in)
  end

  # The same work as a wrong password, whatever is missing.
  defp verify(_unknown_or_oversized, _password) do
    Argon2.no_user_verify()
    refuse(:sign_in)
  end

  defp start_session(user) do
    case Sessions.create(user) do
      {:ok, credentials} ->
        emit(:signed_in)
        {:ok, credentials}

      {:error, :account_suspended} ->
        refuse(:sign_in, :account_suspended)

      {:error, _gone} ->
        refuse(:sign_in)
    end
  end

  defp credential_of(email) do
    Repo.one(
      from(i in Identity,
        join: u in User,
        on: u.id == i.user_id,
        join: c in PasswordCredential,
        on: c.user_id == i.user_id,
        where: i.provider == :email and i.provider_subject == ^email,
        select: {u, c}
      ),
      @quiet
    )
  end

  ## Set or reset (emailed code)

  @doc """
  Sends a password code to `email` if it is an email identity's address. Answers the
  same for every well-formed address.
  """
  @spec request_reset(term(), String.t()) :: {:ok, EmailAuth.requested()} | error()
  def request_reset(email, client_ip), do: EmailAuth.request_password_reset(email, client_ip)

  @doc """
  Sets the password of the user whose email identity received `code`, replacing any
  previous one, and revokes every session of that user. Signs nobody in.
  """
  @spec reset(term(), term(), term(), String.t()) :: :ok | error()
  def reset(email, code, password, client_ip) do
    with {:ok, params} <-
           required(%{email: email, code: code, password: password}, [:email, :code, :password]),
         %{email: email, password: password} = params,
         {:ok, email} <- normalize(email),
         :ok <- policy(password, [email]) do
      email
      |> EmailAuth.verify_password_reset_code(code, client_ip, fn user, now ->
        replace!(user.id, password, now, nil)
      end)
      |> done()
    end
  end

  defp done({:ok, event}) do
    emit(event)
    :ok
  end

  defp done({:error, _reason} = error), do: error

  ## Change (signed in)

  @doc """
  Changes the viewer's password with the current one. Every other session of the user
  is revoked; `session` stays. `:password_not_set` when the user has none yet (set one
  with an emailed code).
  """
  @spec change(User.t(), Session.t(), term(), term()) :: :ok | error()
  def change(%User{id: user_id} = user, %Session{id: session_id}, current_password, password) do
    with {:ok, params} <-
           required(%{current_password: current_password, password: password}, [
             :current_password,
             :password
           ]),
         %{current_password: current, password: password} = params,
         :ok <- policy(password, email_addresses(user)),
         :ok <- limit([user_rule(@change_user, user_id)]),
         {:ok, credential} <- own_credential(user_id),
         :ok <- current_matches(current, credential) do
      fn -> replace_held!(user_id, session_id, credential, password) end
      |> Repo.transaction()
      |> done()
    end
  end

  # Lock order: the credential, then the user and session (as a reset: the challenge,
  # the credential, then the sessions), so the two never deadlock.
  defp replace_held!(user_id, session_id, credential, password) do
    with %PasswordCredential{password_hash: hash} when hash == credential.password_hash <-
           lock_credential(user_id),
         :ok <- Sessions.hold_active(user_id, session_id) do
      replace!(user_id, password, DateTime.utc_now(), session_id)
    else
      {:error, :unauthorized} -> Repo.rollback(:unauthorized)
      # Changed or removed meanwhile (another change or a reset): read again.
      _other -> Repo.rollback(:conflict)
    end
  end

  defp own_credential(user_id) do
    case Repo.get_by(PasswordCredential, [user_id: user_id], @quiet) do
      nil -> {:error, :password_not_set}
      credential -> {:ok, credential}
    end
  end

  defp current_matches(current, credential) do
    if byte_size(current) <= 4 * @max_length and
         Argon2.verify_pass(current, credential.password_hash),
       do: :ok,
       else: refuse(:change)
  end

  @doc "Whether the user has a password."
  @spec set?(User.t()) :: boolean()
  def set?(%User{id: user_id}) do
    Repo.exists?(from(c in PasswordCredential, where: c.user_id == ^user_id), @quiet)
  end

  ## Shared

  # Inside a transaction: stores the new hash (insert or replace), records the event
  # and revokes the user's sessions, except `keep_session_id`. Returns the event.
  defp replace!(user_id, password, now, keep_session_id) do
    hash = Argon2.hash_pwd_salt(password)
    existing = lock_credential(user_id)

    event =
      cond do
        is_nil(existing) -> :password_set
        is_nil(keep_session_id) -> :password_reset
        true -> :password_changed
      end

    case existing do
      # A concurrent first password (another email identity of the same user) can win
      # the unique index between the lock and the insert; the later one replaces it.
      nil ->
        Repo.insert!(
          %PasswordCredential{user_id: user_id, password_hash: hash},
          [
            on_conflict: [set: [password_hash: hash, updated_at: DateTime.utc_now()]],
            conflict_target: :user_id
          ] ++ @quiet
        )

      credential ->
        Repo.update!(change(credential, password_hash: hash), @quiet)
    end

    Repo.insert!(%SecurityEvent{
      user_id: user_id,
      event: event,
      session_id: keep_session_id,
      occurred_at: now
    })

    revoke_sessions!(user_id, keep_session_id, now)
    event
  end

  defp lock_credential(user_id) do
    Repo.one(
      from(c in PasswordCredential, where: c.user_id == ^user_id, lock: "FOR UPDATE"),
      @quiet
    )
  end

  defp revoke_sessions!(user_id, keep_session_id, now) do
    stamp = DateTime.truncate(now, :second)

    query =
      if keep_session_id,
        do:
          from(s in Session,
            where: s.user_id == ^user_id and is_nil(s.revoked_at) and s.id != ^keep_session_id
          ),
        else: from(s in Session, where: s.user_id == ^user_id and is_nil(s.revoked_at))

    Repo.update_all(query,
      set: [revoked_at: stamp, revoked_reason: :password_changed, updated_at: stamp]
    )
  end

  defp email_addresses(%User{id: user_id}) do
    Repo.all(
      from(i in Identity,
        where: i.user_id == ^user_id and i.provider == :email,
        select: i.provider_subject
      ),
      @quiet
    )
  end

  # Length only (NIST SP 800-63B): no composition rules. A password that is one of
  # the account's own addresses is refused.
  defp policy(password, addresses) do
    changeset =
      {%{}, %{password: :string}}
      |> cast(%{password: password}, [:password], empty_values: [])
      |> validate_length(:password, min: @min_length, max: @max_length)
      |> validate_change(:password, fn :password, value ->
        if String.downcase(String.trim(value)) in addresses,
          do: [password: {"must not be your email address", validation: :exclusion}],
          else: []
      end)

    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  defp required(params, fields) do
    types = Map.new(Map.keys(params), &{&1, :string})

    changeset =
      {%{}, types}
      |> cast(params, Map.keys(types), empty_values: [])
      |> validate_required(fields, trim: false)

    if changeset.valid?, do: {:ok, apply_changes(changeset)}, else: {:error, changeset}
  end

  defp normalize(email) do
    case EmailAddress.normalize(email) do
      {:ok, canonical} ->
        {:ok, canonical}

      :error ->
        {:error,
         {%{}, %{email: :string}}
         |> change()
         |> add_error(:email, "is not a valid email address", validation: :format)}
    end
  end

  defp limit(rules) do
    case RateLimit.hit(rules) do
      :ok ->
        :ok

      {:error, {:rate_limited, _seconds}} = limited ->
        :telemetry.execute([:simple_fit, :auth, :password, :rate_limited], %{count: 1}, %{})
        limited
    end
  end

  defp ip_rule({bucket, limit, period}, client_ip),
    do: {bucket, Secrets.rate_limit_key(bucket, client_ip), limit, period}

  defp user_rule({bucket, limit, period}, user_id),
    do: {bucket, Secrets.rate_limit_key(bucket, user_id), limit, period}

  defp target_rules(email) do
    for {window, limit, period} <- @sign_in_target do
      bucket = "password_sign_in:#{window}"
      {bucket, Secrets.rate_limit_key(bucket, email), limit, period}
    end
  end

  defp refuse(operation, reason \\ :invalid_credentials) do
    :telemetry.execute([:simple_fit, :auth, :password, :rejected], %{count: 1}, %{
      operation: operation,
      reason: reason
    })

    {:error, reason}
  end

  defp emit(event),
    do: :telemetry.execute([:simple_fit, :auth, :password, event], %{count: 1}, %{})
end
