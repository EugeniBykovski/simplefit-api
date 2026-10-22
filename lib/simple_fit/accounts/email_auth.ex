defmodule SimpleFit.Accounts.EmailAuth do
  @moduledoc """
  Passwordless email authentication (ADR 0012). Called through
  `SimpleFit.Accounts`; internal to the context.

  Three purposes, never interchangeable:

    * **Email verification** (registration, E01): proves ownership of a new
      address. A 6-digit code *or* a high-entropy link answers the same
      challenge; the first one used closes it. On success the user and its
      email identity are created (ADR 0009 rules: the unique index decides,
      nothing is linked or merged).
    * **Email sign-in** (E17): proves control of the address of an existing
      email identity with a 6-digit code and starts an SF-20 session.
    * **Identity linking** (SF-77, ADR 0024): a signed-in user proves control
      of an address with a 6-digit code entered in the same session; the
      address becomes an email identity of that same user
      (`link_identity/3` rules: never moved, never merged). Never starts a
      session and never creates a user.

  ## Sessions after verification (Design Version 66)

  A verification challenge issues a session **only** when its code is
  entered by the client that started the registration (it presents the
  registration token it received). The session is created in the same
  transaction that closes the challenge as `code_verified`. The E01 link
  verifies the address from any device but never issues a session, neither
  to the device that opened it nor to the registration device: that device
  sees `verified_elsewhere` and must authenticate again with an email
  sign-in code (E17). A registration token alone is never enough.

  ## Enumeration resistance

  Requests answer the same for every well-formed address. When there is
  nothing to send (sign-up for an address that already has an identity,
  sign-in for one that has none) a decoy challenge is stored whose verifiers
  match nothing, and no email is sent. Decoys expire, count wrong codes and
  are superseded like real challenges, so neither responses, nor expiry,
  nor attempt exhaustion reveal whether an account exists. Limits are keyed
  by the target, not by account existence.

  ## Results

    * `{:error, %Ecto.Changeset{}}` - malformed input (`validation_error`)
    * `{:error, {:rate_limited, retry_after}}`
    * `{:error, :code_invalid}` - wrong code
    * `{:error, :code_expired}` - expired, superseded, exhausted, used or
      unknown: a new code is needed
    * `{:error, :verified_elsewhere}` - the registration was verified through
      the link; this client must sign in
    * `{:error, :conflict}` - the address already has an identity
      (registration code answered after it was taken; identity link: it
      belongs to another user, reachable only after mailbox proof)
    * `{:error, :unauthorized}` - identity link: the session asking is no
      longer valid (logged out, revoked, expired or deleted)
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.{EmailAddress, Identity, Session, Sessions, User}
  alias SimpleFit.Accounts.EmailAuth.{Challenge, Secrets}
  alias SimpleFit.{Email, RateLimit, Repo}
  alias SimpleFit.Email.Templates

  # Queries carrying digests, verifiers or the email never reach the debug
  # query log.
  @quiet [log: false]

  @request_ip {"email_code_request:ip", 20, 600}
  @verify_ip {"email_code_verify:ip", 60, 600}
  @status_ip {"registration_status:ip", 120, 600}
  @target_windows [{"minute", 1, 60}, {"hour", 5, 3_600}, {"day", 10, 86_400}]
  # Identity linking: the same windows per user (any address), so a user
  # cannot rotate addresses or sessions to request more codes.
  @user_windows @target_windows

  @typedoc "An expected failure."
  @type error ::
          {:error, Ecto.Changeset.t()}
          | {:error, {:rate_limited, pos_integer()}}
          | {:error, :code_invalid | :code_expired | :verified_elsewhere | :conflict}
          | {:error, :unauthorized}

  @typedoc "A confirmed identity link: the email identity and whether it is new."
  @type linked :: %{identity: Identity.t(), outcome: :linked | :already_linked}

  @typedoc "What a code request returns to the client."
  @type requested :: %{
          optional(:registration_token) => String.t(),
          expires_in_seconds: pos_integer(),
          resend_after_seconds: pos_integer()
        }

  ## Configuration

  @doc """
  The email authentication policy and key material, validated. Raises when
  missing or inconsistent, so a deployment fails at boot.
  """
  @spec config!() :: %{
          challenge_ttl: pos_integer(),
          max_failed_attempts: pos_integer(),
          resend_cooldown: pos_integer(),
          web_app_url: String.t()
        }
  def config! do
    opts = Application.get_env(:simple_fit, __MODULE__, [])
    ttl = opts[:challenge_ttl]

    unless is_integer(ttl) and ttl >= 60 and rem(ttl, 60) == 0 do
      raise ArgumentError, "#{inspect(__MODULE__)}: challenge_ttl must be whole minutes (seconds)"
    end

    unless opts[:max_failed_attempts] in 1..5 do
      raise ArgumentError, "#{inspect(__MODULE__)}: max_failed_attempts must be 1..5"
    end

    unless is_integer(opts[:resend_cooldown]) and opts[:resend_cooldown] > 0 do
      raise ArgumentError, "#{inspect(__MODULE__)}: resend_cooldown must be positive (seconds)"
    end

    unless is_binary(opts[:web_app_url]) do
      raise ArgumentError, "#{inspect(__MODULE__)}: web_app_url is missing (WEB_APP_URL)"
    end

    # Fails on missing or short key material.
    _digest = Secrets.target_digest("config@check.invalid")

    %{
      challenge_ttl: ttl,
      max_failed_attempts: opts[:max_failed_attempts],
      resend_cooldown: opts[:resend_cooldown],
      web_app_url: opts[:web_app_url]
    }
  end

  @doc """
  Parses `WEB_APP_URL`: an origin (`scheme://host[:port]`, no path, query,
  fragment or user info). With `require_https: true` only `https` is
  accepted. Raises on anything else.
  """
  @spec parse_web_app_url!(String.t(), keyword()) :: String.t()
  def parse_web_app_url!(url, opts \\ []) when is_binary(url) do
    schemes = if opts[:require_https], do: ["https"], else: ["https", "http"]

    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil, userinfo: nil} = uri
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        if scheme in schemes,
          do: URI.to_string(%URI{uri | path: nil}),
          else: raise(ArgumentError, "WEB_APP_URL must use #{Enum.join(schemes, " or ")}")

      _invalid ->
        raise ArgumentError, "WEB_APP_URL must be an origin such as https://app.example.com"
    end
  end

  ## Registration (email verification)

  @doc """
  Starts (or restarts) the email verification of a registration. Always
  answers the same for a well-formed address; the returned
  `registration_token` identifies this registration to the client that
  started it.
  """
  @spec request_registration(term(), String.t()) :: {:ok, requested()} | error()
  def request_registration(email, client_ip) do
    request(:verification, email, client_ip)
  end

  @doc """
  Verifies a registration with the code entered on the client that holds
  `registration_token`. On success the user and email identity exist and
  the one session of this registration is returned.
  """
  @spec verify_registration_code(term(), term(), String.t()) ::
          {:ok, Sessions.credentials()} | error()
  def verify_registration_code(registration_token, code, client_ip) do
    with {:ok, %{token: token, code: code}} <-
           validate(%{token: registration_token, code: code}, %{token: :string, code: :string}),
         :ok <- validate_code(code),
         :ok <- limit([ip_rule(@verify_ip, client_ip)]) do
      with_token(:registration, token, :verification, fn hash ->
        answer_registration(lock_by_registration(hash), code)
      end)
    end
  end

  @doc """
  Verifies a registration through its E01 link, from any device. Never
  starts a session. `{:ok, :verified}` the first time, `{:ok,
  :already_verified}` when the address is already verified.
  """
  @spec verify_link(term(), String.t()) ::
          {:ok, :verified | :already_verified} | error()
  def verify_link(link_token, client_ip) do
    with {:ok, %{token: token}} <- validate(%{token: link_token}, %{token: :string}),
         :ok <- limit([ip_rule(@verify_ip, client_ip)]) do
      with_token(:link, token, :verification, fn hash -> answer_link(lock_by_link(hash)) end)
    end
  end

  @doc """
  What the client holding `registration_token` should show:

    * `:pending` - waiting for the code
    * `:completed` - verified with this client's code (its session was issued)
    * `:verified_elsewhere` - verified through the link; this client must
      sign in with an email sign-in code
    * `:expired` - expired, replaced, exhausted or unknown
  """
  @spec registration_status(term(), String.t()) ::
          {:ok, :pending | :completed | :verified_elsewhere | :expired} | error()
  def registration_status(registration_token, client_ip) do
    with {:ok, %{token: token}} <- validate(%{token: registration_token}, %{token: :string}),
         :ok <- limit([ip_rule(@status_ip, client_ip)]) do
      challenge =
        case Secrets.parse_token(:registration, token) do
          {:ok, hash} -> Repo.get_by(Challenge, [registration_token_hash: hash], @quiet)
          :error -> nil
        end

      {:ok, status(challenge, now())}
    end
  end

  ## Sign-in

  @doc """
  Sends an email sign-in code if the address has an email identity. Always
  answers the same for a well-formed address.
  """
  @spec request_sign_in(term(), String.t()) :: {:ok, requested()} | error()
  def request_sign_in(email, client_ip), do: request(:sign_in, email, client_ip)

  @doc "Verifies an email sign-in code and starts an SF-20 session."
  @spec verify_sign_in_code(term(), term(), String.t()) ::
          {:ok, Sessions.credentials()} | error()
  def verify_sign_in_code(email, code, client_ip) do
    with {:ok, %{email: email, code: code}} <-
           validate(%{email: email, code: code}, %{email: :string, code: :string}),
         {:ok, email} <- normalize(email),
         :ok <- validate_code(code),
         :ok <- limit([ip_rule(@verify_ip, client_ip)]) do
      digest = Secrets.target_digest(email)
      transact(fn -> answer_sign_in(lock_latest(:sign_in, digest), email, code) end)
    end
  end

  ## Identity linking (SF-77)

  @doc """
  Sends a code (`Templates.email_link_code/1`) that lets `user`, in
  `session`, add `email` as one of its email identities. Answers the same
  for every well-formed address, whoever owns it: ownership is only checked
  after the code proves control of the mailbox. A new request (any address)
  supersedes the user's open link challenge.
  """
  @spec request_identity_link(User.t(), Session.t(), term(), String.t()) ::
          {:ok, requested()} | error()
  def request_identity_link(%User{id: user_id}, %Session{id: session_id}, email, client_ip)
      when is_binary(user_id) and is_binary(session_id) do
    with {:ok, %{email: email}} <- validate(%{email: email}, %{email: :string}),
         {:ok, email} <- normalize(email),
         :ok <-
           limit([
             ip_rule(@request_ip, client_ip)
             | user_rules(user_id) ++ target_rules(:identity_link, email)
           ]) do
      config = config!()

      case issue_link(user_id, session_id, email, config, 3) do
        :ok ->
          emit(:requested, :identity_link, %{outcome: :accepted})

          {:ok,
           %{
             expires_in_seconds: config.challenge_ttl,
             resend_after_seconds: config.resend_cooldown
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Confirms a link with the code sent to `email`, for `user` in the session
  that requested it. On success the address is an email identity of `user`
  (`:linked`, or `:already_linked` when it already was). Another user's
  address is a `:conflict`: nothing is moved or merged. A session that is no
  longer valid is `:unauthorized`, decided under a lock, so a concurrent
  logout either happens before (no link) or after the link.
  """
  @spec confirm_identity_link(User.t(), Session.t(), term(), term(), String.t()) ::
          {:ok, linked()} | error()
  def confirm_identity_link(%User{id: user_id}, %Session{id: session_id}, email, code, client_ip)
      when is_binary(user_id) and is_binary(session_id) do
    with {:ok, %{email: email, code: code}} <-
           validate(%{email: email, code: code}, %{email: :string, code: :string}),
         {:ok, email} <- normalize(email),
         :ok <- validate_code(code),
         :ok <- limit([ip_rule(@verify_ip, client_ip)]) do
      transact(fn -> answer_identity_link(user_id, session_id, email, code) end)
    end
  end

  ## Cleanup

  @doc """
  Deletes challenges that closed or expired before `cutoff`. Returns the
  number removed.
  """
  @spec delete_finished_challenges(DateTime.t()) :: non_neg_integer()
  def delete_finished_challenges(cutoff) do
    {count, _} =
      Repo.delete_all(
        from(c in Challenge,
          where:
            (not is_nil(c.closed_at) and c.closed_at < ^cutoff) or
              (is_nil(c.closed_at) and c.expires_at < ^cutoff)
        ),
        @quiet
      )

    count
  end

  ## Requests

  defp request(purpose, email, client_ip) do
    with {:ok, %{email: email}} <- validate(%{email: email}, %{email: :string}),
         {:ok, email} <- normalize(email),
         :ok <- limit([ip_rule(@request_ip, client_ip) | target_rules(purpose, email)]) do
      config = config!()
      deliver? = deliverable?(purpose, email)

      case issue(purpose, email, deliver?, config, 3) do
        {:ok, result} ->
          emit(:requested, purpose, %{outcome: :accepted})

          {:ok,
           Map.merge(result, %{
             expires_in_seconds: config.challenge_ttl,
             resend_after_seconds: config.resend_cooldown
           })}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A verification email goes to a new address, a sign-in email to an
  # existing email identity; everything else is a decoy.
  defp deliverable?(purpose, email) do
    exists? =
      Repo.exists?(
        from(i in Identity, where: i.provider == :email and i.provider_subject == ^email),
        @quiet
      )

    if purpose == :verification, do: not exists?, else: exists?
  end

  # Supersedes the open challenge and inserts the new one atomically. A
  # concurrent request for the same target can win the one-open-challenge
  # index between the two statements; the loser simply retries.
  defp issue(purpose, email, deliver?, config, attempts_left) do
    result =
      Repo.transaction(fn ->
        now = now()
        digest = Secrets.target_digest(email)
        supersede(purpose, digest, now)

        {challenge, credentials} = build(purpose, email, digest, deliver?, now, config)

        case Repo.insert(open_changeset(challenge), @quiet) do
          {:ok, _challenge} -> :ok
          {:error, _changeset} -> Repo.rollback(:busy)
        end

        # Enqueued in the same transaction: a challenge exists only if its
        # email was queued, and vice versa.
        if deliver?, do: enqueue(purpose, email, credentials, config)

        Map.take(credentials, [:registration_token])
      end)

    case result do
      {:error, :busy} when attempts_left > 1 ->
        issue(purpose, email, deliver?, config, attempts_left - 1)

      {:error, :busy} ->
        {:error, {:rate_limited, config.resend_cooldown}}

      other ->
        other
    end
  end

  # As `issue/5`, per user: supersedes the user's open link challenge and
  # inserts the new one with its email job, atomically.
  defp issue_link(user_id, session_id, email, config, attempts_left) do
    result =
      Repo.transaction(fn ->
        now = now()

        Repo.update_all(
          from(c in Challenge,
            where: c.purpose == :identity_link and c.user_id == ^user_id and is_nil(c.closed_at)
          ),
          [set: [closed_at: now, closed_reason: :superseded]],
          @quiet
        )

        id = Ecto.UUID.generate()
        code = Secrets.generate_code()

        challenge = %Challenge{
          id: id,
          purpose: :identity_link,
          user_id: user_id,
          session_id: session_id,
          email: email,
          target_digest: Secrets.target_digest(email),
          code_hash: Secrets.code_verifier(:identity_link, id, code),
          expires_at: DateTime.add(now, config.challenge_ttl),
          inserted_at: now
        }

        case Repo.insert(link_changeset(challenge), @quiet) do
          {:ok, _challenge} -> :ok
          {:error, changeset} -> Repo.rollback(insert_failure(changeset))
        end

        enqueue(:identity_link, email, %{code: code}, config)
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, :busy} when attempts_left > 1 ->
        issue_link(user_id, session_id, email, config, attempts_left - 1)

      {:error, :busy} ->
        {:error, {:rate_limited, config.resend_cooldown}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_changeset(challenge) do
    challenge
    |> change()
    |> unique_constraint(:user_id, name: :email_auth_challenges_one_open_link_index)
    |> foreign_key_constraint(:user_id, name: :email_auth_challenges_user_id_fkey)
    |> foreign_key_constraint(:session_id, name: :email_auth_challenges_session_id_fkey)
  end

  # A concurrent request of the same user won the one-open index (retry), or
  # the user or session was deleted meanwhile.
  defp insert_failure(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
         opts[:constraint] == :unique
       end),
       do: :busy,
       else: :unauthorized
  end

  defp build(purpose, email, digest, deliver?, now, config) do
    id = Ecto.UUID.generate()
    code = Secrets.generate_code()

    code_hash =
      if deliver?,
        do: Secrets.code_verifier(purpose, id, code),
        else: Secrets.unmatchable_verifier()

    challenge = %Challenge{
      id: id,
      purpose: purpose,
      target_digest: digest,
      code_hash: code_hash,
      expires_at: DateTime.add(now, config.challenge_ttl),
      inserted_at: now
    }

    case purpose do
      :verification ->
        {link_token, link_hash} = Secrets.generate_token(:link)
        {registration_token, registration_hash} = Secrets.generate_token(:registration)

        {%{
           challenge
           | email: email,
             link_token_hash: link_hash,
             registration_token_hash: registration_hash
         }, %{code: code, link_token: link_token, registration_token: registration_token}}

      :sign_in ->
        {challenge, %{code: code}}
    end
  end

  defp open_changeset(challenge) do
    challenge
    |> change()
    |> unique_constraint([:purpose, :target_digest], name: :email_auth_challenges_one_open_index)
  end

  defp supersede(purpose, digest, now) do
    Repo.update_all(
      from(c in Challenge,
        where: c.purpose == ^purpose and c.target_digest == ^digest and is_nil(c.closed_at)
      ),
      [set: [closed_at: now, closed_reason: :superseded]],
      @quiet
    )
  end

  defp enqueue(purpose, email, credentials, config) do
    minutes = div(config.challenge_ttl, 60)

    rendered =
      case purpose do
        :verification ->
          Templates.verify_email(
            code: credentials.code,
            verify_url: "#{config.web_app_url}/verify-email#token=#{credentials.link_token}",
            expires_in_minutes: minutes
          )

        :sign_in ->
          Templates.sign_in_code(code: credentials.code, expires_in_minutes: minutes)

        :identity_link ->
          Templates.email_link_code(code: credentials.code, expires_in_minutes: minutes)
      end

    with {:ok, rendered} <- rendered,
         {:ok, message} <- Templates.to_message(rendered, to: email),
         {:ok, _job} <- Email.deliver_later(message) do
      emit(:sent, purpose, %{outcome: :queued})
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  ## Answers

  defp answer_registration(nil, _code), do: reject(:verification, :code_expired)

  defp answer_registration(%Challenge{} = challenge, code) do
    now = now()

    cond do
      challenge.closed_reason == :link_verified ->
        reject(:verification, :verified_elsewhere)

      not Challenge.open?(challenge, now) ->
        reject(:verification, :code_expired)

      not Secrets.code_matches?(:verification, challenge.id, code, challenge.code_hash) ->
        wrong_code(challenge, now)

      true ->
        case register(challenge.email, now) do
          {:ok, user} ->
            close(challenge, :code_verified, now, session_created_at: now)
            start_session(user, :verification)

          :conflict ->
            close(challenge, :conflict, now)
            reject(:verification, :conflict)
        end
    end
  end

  defp answer_link(nil), do: reject(:verification, :code_expired)

  defp answer_link(%Challenge{} = challenge) do
    now = now()

    cond do
      challenge.closed_reason in [:code_verified, :link_verified, :conflict] ->
        {:ok, :already_verified}

      not Challenge.open?(challenge, now) ->
        reject(:verification, :code_expired)

      true ->
        # Never a session: the link proves ownership of the address only.
        case register(challenge.email, now) do
          {:ok, _user} ->
            close(challenge, :link_verified, now)
            emit(:verified, :verification, %{channel: :link})
            {:ok, :verified}

          :conflict ->
            close(challenge, :conflict, now)
            emit(:rejected, :verification, %{reason: :conflict})
            {:ok, :already_verified}
        end
    end
  end

  defp answer_sign_in(nil, _email, _code), do: reject(:sign_in, :code_invalid)

  defp answer_sign_in(%Challenge{} = challenge, email, code) do
    now = now()

    cond do
      not Challenge.open?(challenge, now) ->
        reject(:sign_in, :code_expired)

      not Secrets.code_matches?(:sign_in, challenge.id, code, challenge.code_hash) ->
        wrong_code(challenge, now)

      true ->
        case Repo.one(
               from(u in User,
                 join: i in assoc(u, :identities),
                 where: i.provider == :email and i.provider_subject == ^email
               ),
               @quiet
             ) do
          %User{} = user ->
            close(challenge, :code_verified, now, session_created_at: now)
            start_session(user, :sign_in)

          nil ->
            # The identity disappeared after the code was sent.
            close(challenge, :conflict, now)
            reject(:sign_in, :code_expired)
        end
    end
  end

  # The user and its session are share-locked first: a concurrent logout,
  # revocation or account deletion waits for this answer, or has already
  # happened and the session is refused. Only then is the user's latest link
  # challenge locked, so concurrent confirmations are answered one by one.
  defp answer_identity_link(user_id, session_id, email, code) do
    now = now()

    if session_active?(lock_session_of(user_id, session_id), now) do
      answer_identity_link(lock_latest_link(user_id), session_id, email, code, now)
    else
      reject(:identity_link, :unauthorized)
    end
  end

  defp answer_identity_link(nil, _session_id, _email, _code, _now),
    do: reject(:identity_link, :code_expired)

  defp answer_identity_link(%Challenge{} = challenge, session_id, email, code, now) do
    cond do
      not Challenge.open?(challenge, now) ->
        reject(:identity_link, :code_expired)

      # Requested in another session of the same user: that session must
      # enter it, as a registration code must be entered where it started.
      challenge.session_id != session_id ->
        reject(:identity_link, :code_expired)

      # A code for another address counts as a wrong code: the verifier is
      # bound to the challenge, the address to the challenge row.
      challenge.email != email or
          not Secrets.code_matches?(:identity_link, challenge.id, code, challenge.code_hash) ->
        wrong_code(challenge, now)

      true ->
        attach(challenge, email, now)
    end
  end

  # ON CONFLICT DO NOTHING keeps the transaction usable when the address is
  # already an identity, or becomes one in a concurrent transaction (the
  # insert waits for it): the unique index decides, and the owner is read
  # back. Nothing is moved; no user is created.
  defp attach(%Challenge{user_id: user_id} = challenge, email, now) do
    stamp = DateTime.truncate(now, :second)

    {count, _} =
      Repo.insert_all(
        Identity,
        [
          %{
            id: Ecto.UUID.generate(),
            user_id: user_id,
            provider: :email,
            provider_subject: email,
            inserted_at: stamp,
            updated_at: stamp
          }
        ],
        [on_conflict: :nothing, conflict_target: [:provider, :provider_subject]] ++ @quiet
      )

    case Repo.get_by(Identity, [provider: :email, provider_subject: email], @quiet) do
      %Identity{user_id: ^user_id} = identity ->
        outcome = if count == 1, do: :linked, else: :already_linked
        close(challenge, :code_verified, now)
        emit(:verified, :identity_link, %{channel: :code, outcome: outcome})
        {:ok, %{identity: identity, outcome: outcome}}

      _other_owner ->
        close(challenge, :conflict, now)
        reject(:identity_link, :conflict)
    end
  end

  defp session_active?(%Session{revoked_at: nil, expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp session_active?(_revoked_expired_or_missing, _now), do: false

  defp wrong_code(challenge, now) do
    attempts = challenge.failed_attempts + 1

    if attempts >= config!().max_failed_attempts do
      close(challenge, :exhausted, now, failed_attempts: attempts)
    else
      Repo.update_all(
        from(c in Challenge, where: c.id == ^challenge.id),
        [set: [failed_attempts: attempts]],
        @quiet
      )
    end

    reject(challenge.purpose, :code_invalid)
  end

  defp close(challenge, reason, now, extra \\ []) do
    Repo.update_all(
      from(c in Challenge, where: c.id == ^challenge.id),
      [set: [closed_at: now, closed_reason: reason] ++ extra],
      @quiet
    )
  end

  # Creates the user and its email identity (ADR 0009) unless the identity
  # already exists. ON CONFLICT DO NOTHING keeps the surrounding transaction
  # usable when a concurrent registration wins the unique index: nothing is
  # linked, moved or merged, and the new user is removed again.
  defp register(email, now) do
    user = Repo.insert!(%User{}, @quiet)
    stamp = DateTime.truncate(now, :second)

    {count, _} =
      Repo.insert_all(
        Identity,
        [
          %{
            id: Ecto.UUID.generate(),
            user_id: user.id,
            provider: :email,
            provider_subject: email,
            inserted_at: stamp,
            updated_at: stamp
          }
        ],
        [on_conflict: :nothing, conflict_target: [:provider, :provider_subject]] ++ @quiet
      )

    if count == 1 do
      {:ok, user}
    else
      Repo.delete!(user, @quiet)
      :conflict
    end
  end

  defp start_session(user, purpose) do
    case Sessions.create(user) do
      {:ok, credentials} ->
        emit(:verified, purpose, %{channel: :code})
        {:ok, credentials}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp status(nil, _now), do: :expired

  defp status(%Challenge{closed_reason: :link_verified}, _now), do: :verified_elsewhere
  defp status(%Challenge{closed_reason: :code_verified}, _now), do: :completed

  defp status(%Challenge{} = challenge, now),
    do: if(Challenge.open?(challenge, now), do: :pending, else: :expired)

  ## Lookups (row-locked for the duration of the answer)

  defp lock_by_registration(hash) do
    Repo.one(
      from(c in Challenge, where: c.registration_token_hash == ^hash, lock: "FOR UPDATE"),
      @quiet
    )
  end

  defp lock_by_link(hash) do
    Repo.one(from(c in Challenge, where: c.link_token_hash == ^hash, lock: "FOR UPDATE"), @quiet)
  end

  defp lock_latest(purpose, digest) do
    Repo.one(
      from(c in Challenge,
        where: c.purpose == ^purpose and c.target_digest == ^digest,
        order_by: [desc: c.inserted_at],
        limit: 1,
        lock: "FOR UPDATE"
      ),
      @quiet
    )
  end

  # The user row first (FOR KEY SHARE), then its session (FOR SHARE): the
  # order in which deleting a user locks them (the user row, then the
  # cascade to sessions), so a concurrent deletion waits or wins without a
  # deadlock. A deleted user or session is nil; a logout waits for this
  # transaction or has already committed.
  defp lock_session_of(user_id, session_id) do
    with %User{} <-
           Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR KEY SHARE"), @quiet) do
      Repo.one(
        from(s in Session,
          where: s.id == ^session_id and s.user_id == ^user_id,
          lock: "FOR SHARE"
        ),
        @quiet
      )
    end
  end

  defp lock_latest_link(user_id) do
    Repo.one(
      from(c in Challenge,
        where: c.purpose == :identity_link and c.user_id == ^user_id,
        order_by: [desc: c.inserted_at],
        limit: 1,
        lock: "FOR UPDATE"
      ),
      @quiet
    )
  end

  ## Helpers

  # Answers in a transaction for a well-formed token; a malformed one is
  # unknown, like a token that matches nothing.
  defp with_token(kind, token, purpose, answer) do
    case Secrets.parse_token(kind, token) do
      {:ok, hash} -> transact(fn -> answer.(hash) end)
      :error -> reject(purpose, :code_expired)
    end
  end

  # Runs `fun` in a transaction. Expected failures are returned (not rolled
  # back) so that attempt counters and closed states are committed.
  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject(purpose, reason) do
    emit(:rejected, purpose, %{reason: reason})
    {:error, reason}
  end

  defp limit(rules) do
    case RateLimit.hit(rules) do
      :ok ->
        :ok

      {:error, {:rate_limited, _seconds}} = limited ->
        :telemetry.execute([:simple_fit, :auth, :email, :rate_limited], %{count: 1}, %{})
        limited
    end
  end

  defp ip_rule({bucket, limit, period}, client_ip),
    do: {bucket, Secrets.rate_limit_key(bucket, client_ip), limit, period}

  defp user_rules(user_id) do
    for {window, limit, period} <- @user_windows do
      bucket = "identity_link_user:#{window}"
      {bucket, Secrets.rate_limit_key(bucket, user_id), limit, period}
    end
  end

  defp target_rules(purpose, email) do
    for {window, limit, period} <- @target_windows do
      bucket = "#{purpose}_request:#{window}"
      {bucket, Secrets.rate_limit_key(bucket, email), limit, period}
    end
  end

  defp validate(params, types) do
    changeset =
      {%{}, types}
      |> cast(params, Map.keys(types))
      |> validate_required(Map.keys(types))

    if changeset.valid?, do: {:ok, apply_changes(changeset)}, else: {:error, changeset}
  end

  defp normalize(email) do
    case EmailAddress.normalize(email) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> field_error(:email, "is not a valid email address")
    end
  end

  defp validate_code(code) do
    if Secrets.code?(code), do: :ok, else: field_error(:code, "must be 6 digits")
  end

  defp field_error(field, message) do
    {:error,
     {%{}, %{field => :string}}
     |> change()
     |> add_error(field, message, validation: :format)}
  end

  defp emit(event, purpose, metadata) do
    :telemetry.execute(
      [:simple_fit, :auth, :email, event],
      %{count: 1},
      Map.put(metadata, :purpose, purpose)
    )
  end

  defp now, do: DateTime.utc_now()
end
