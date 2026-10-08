defmodule SimpleFit.Accounts do
  @moduledoc """
  Users, the identities that sign them in (ADR 0009), their SimpleFit
  sessions (ADR 0010), passwordless email authentication (ADR 0012) and
  shared account registration: basics and consents (ADR 0016).

  One person is one global `User`; a user owns any number of `Identity`
  records (email, Google, Apple). This context only stores and resolves them:
  proving that a caller controls an identity (email codes, Google and Apple
  token verification) belongs to the authentication flows built on top of it.

  Rules:

    * `{provider, provider_subject}` identifies one identity of one user. The
      database unique index is the authority, also under concurrency.
    * Identities are never moved between users and users are never merged.
      An identity that belongs to someone else is a `:conflict`, never a
      silent transfer.
    * An email reported by Google or Apple is not a key. Nothing here links
      identities because their emails match; linking is always an explicit
      `link_identity/3` on a user the caller has authenticated.

  Results: `{:ok, value}`, `{:error, :not_found}`, `{:error, :conflict}`, or
  `{:error, %Ecto.Changeset{}}` for an unsupported provider or an invalid
  subject (rendered as `validation_error`). Conflicts carry no detail about
  who owns an identity.
  """

  import Ecto.Changeset, only: [apply_changes: 1, put_change: 3]
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.{
    AppleAuth,
    EmailAddress,
    EmailAuth,
    GoogleAuth,
    Identity,
    Registration,
    Sessions,
    User
  }

  alias SimpleFit.Repo

  @typedoc "A supported identity provider: `:email`, `:google` or `:apple`."
  @type provider :: Identity.provider()

  @typedoc "An identity reference as received: provider and subject, not yet validated."
  @type provider_input :: provider() | String.t()

  # Identity queries carry provider subjects (Google/Apple account ids, email
  # addresses) as parameters; Ecto's query log (debug level) would print
  # them, so these queries are not logged (ADR 0008, ADR 0014).
  @unlogged [log: false]

  @type validation_error :: {:error, Ecto.Changeset.t()}

  @doc """
  Canonical form of an email address (see `SimpleFit.Accounts.EmailAddress`),
  or `:error` when it is not usable as an email identity.
  """
  @spec normalize_email(term()) :: {:ok, String.t()} | :error
  defdelegate normalize_email(address), to: EmailAddress, as: :normalize

  @doc """
  Finds the identity `{provider, subject}`. Email subjects are matched in
  canonical form, so `" User@Example.com "` finds `user@example.com`.
  """
  @spec get_identity(provider_input(), term()) ::
          {:ok, Identity.t()} | {:error, :not_found} | validation_error()
  def get_identity(provider, subject) do
    with {:ok, key} <- identity_key(provider, subject) do
      case Repo.get_by(Identity, key, @unlogged) do
        nil -> {:error, :not_found}
        identity -> {:ok, identity}
      end
    end
  end

  @doc "The user that owns the identity `{provider, subject}`."
  @spec resolve_user(provider_input(), term()) ::
          {:ok, User.t()} | {:error, :not_found} | validation_error()
  def resolve_user(provider, subject) do
    with {:ok, key} <- identity_key(provider, subject) do
      query =
        from u in User,
          join: i in assoc(u, :identities),
          where: i.provider == ^key.provider and i.provider_subject == ^key.provider_subject

      case Repo.one(query, @unlogged) do
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    end
  end

  @doc """
  Creates a new user together with its first identity, atomically.

  Returns the user with `identities` loaded. If the identity already exists
  (including when a concurrent registration wins the race) nothing is created
  and the result is `{:error, :conflict}`; callers that want sign-in semantics
  resolve the existing identity with `resolve_user/2`.
  """
  @spec register_user(provider_input(), term()) ::
          {:ok, User.t()} | {:error, :conflict} | validation_error()
  def register_user(provider, subject) do
    with {:ok, changeset} <- validated_changeset(provider, subject) do
      changeset
      |> insert_user_with_identity()
      |> registration_result()
    end
  end

  @doc """
  Attaches the identity `{provider, subject}` to `user`, for an explicit
  linking request by that (already authenticated) user.

    * Already linked to the same user: `{:ok, identity}` (idempotent).
    * Owned by another user: `{:error, :conflict}`. Nothing is transferred.
    * `user` no longer exists: `{:error, :not_found}`.
  """
  @spec link_identity(User.t(), provider_input(), term()) ::
          {:ok, Identity.t()} | {:error, :conflict | :not_found} | validation_error()
  def link_identity(%User{id: user_id}, provider, subject) when is_binary(user_id) do
    with {:ok, changeset} <- validated_changeset(provider, subject) do
      key = changeset |> apply_changes() |> Map.take([:provider, :provider_subject])

      case Repo.get_by(Identity, key, @unlogged) do
        nil -> insert_link(changeset, user_id, key)
        %Identity{user_id: ^user_id} = identity -> {:ok, identity}
        %Identity{} -> {:error, :conflict}
      end
    end
  end

  ## Sessions (ADR 0010)

  @doc """
  Starts a SimpleFit session for a user that an authentication flow has
  already established (email, Google, Apple, ...), and returns its first
  credentials. The session does not know which provider it was.
  """
  @spec create_session(User.t()) :: {:ok, Sessions.credentials()} | {:error, :not_found}
  defdelegate create_session(user), to: Sessions, as: :create

  @doc "Resolves the viewer (user and session) of an access token, or `:unauthorized`."
  @spec authenticate_access_token(String.t()) ::
          {:ok, Sessions.viewer()} | {:error, :unauthorized}
  defdelegate authenticate_access_token(token), to: Sessions, as: :authenticate

  @doc """
  Rotates a refresh token. Every failure, including a reused token (which
  also revokes its session), is `{:error, :unauthorized}`.
  """
  @spec refresh_session(String.t()) :: {:ok, Sessions.credentials()} | {:error, :unauthorized}
  defdelegate refresh_session(token), to: Sessions, as: :refresh

  @doc "Logs out the session behind an access or refresh token. Always `:ok`."
  @spec revoke_session({:access, String.t()} | {:refresh, String.t()}) :: :ok
  defdelegate revoke_session(credential), to: Sessions, as: :revoke_by_credential

  ## Passwordless email authentication (ADR 0012)

  @doc """
  Starts the email verification of a registration (E01). Answers the same
  for every well-formed address; see `SimpleFit.Accounts.EmailAuth`.
  """
  @spec request_email_registration(term(), String.t()) ::
          {:ok, EmailAuth.requested()} | EmailAuth.error()
  defdelegate request_email_registration(email, client_ip),
    to: EmailAuth,
    as: :request_registration

  @doc """
  Verifies a registration with the code entered on the client that started
  it, and returns the registration's one session.
  """
  @spec verify_email_registration_code(term(), term(), String.t()) ::
          {:ok, Sessions.credentials()} | EmailAuth.error()
  defdelegate verify_email_registration_code(registration_token, code, client_ip),
    to: EmailAuth,
    as: :verify_registration_code

  @doc "Verifies a registration through its E01 link. Never starts a session."
  @spec verify_email_link(term(), String.t()) ::
          {:ok, :verified | :already_verified} | EmailAuth.error()
  defdelegate verify_email_link(link_token, client_ip), to: EmailAuth, as: :verify_link

  @doc "The state of a registration, for the client holding its registration token."
  @spec email_registration_status(term(), String.t()) ::
          {:ok, :pending | :completed | :verified_elsewhere | :expired} | EmailAuth.error()
  defdelegate email_registration_status(registration_token, client_ip),
    to: EmailAuth,
    as: :registration_status

  @doc "Sends an email sign-in code (E17) if the address has an email identity."
  @spec request_email_sign_in(term(), String.t()) ::
          {:ok, EmailAuth.requested()} | EmailAuth.error()
  defdelegate request_email_sign_in(email, client_ip), to: EmailAuth, as: :request_sign_in

  @doc "Verifies an email sign-in code and starts a session."
  @spec verify_email_sign_in_code(term(), term(), String.t()) ::
          {:ok, Sessions.credentials()} | EmailAuth.error()
  defdelegate verify_email_sign_in_code(email, code, client_ip),
    to: EmailAuth,
    as: :verify_sign_in_code

  ## Google sign-in (ADR 0013)

  @doc """
  Signs in with a Google ID token verified by `SimpleFit.Identity`, creating
  the user and its Google identity on first use (never linked by email).
  See `SimpleFit.Accounts.GoogleAuth`.
  """
  @spec authenticate_with_google(term(), String.t()) ::
          {:ok, GoogleAuth.result()} | GoogleAuth.error()
  defdelegate authenticate_with_google(id_token, client_ip), to: GoogleAuth, as: :authenticate

  ## Sign in with Apple (ADR 0014)

  @doc """
  Signs in with an Apple identity token and the raw nonce of its request,
  verified by `SimpleFit.Identity`, creating the user and its Apple identity
  on first use (never linked by email). See `SimpleFit.Accounts.AppleAuth`.
  """
  @spec authenticate_with_apple(term(), term(), String.t()) ::
          {:ok, AppleAuth.result()} | AppleAuth.error()
  defdelegate authenticate_with_apple(id_token, nonce, client_ip),
    to: AppleAuth,
    as: :authenticate

  # The user and its first identity commit together or not at all: a failed
  # identity insert (for example the unique index, under a race) rolls the
  # new user back.
  defp insert_user_with_identity(changeset) do
    Repo.transaction(fn ->
      user = Repo.insert!(%User{})

      case changeset |> put_change(:user_id, user.id) |> Repo.insert(@unlogged) do
        {:ok, identity} -> %{user | identities: [identity]}
        {:error, failed} -> Repo.rollback(failed)
      end
    end)
  end

  defp registration_result({:ok, user}), do: {:ok, user}

  defp registration_result({:error, failed}) do
    if identity_taken?(failed), do: {:error, :conflict}, else: {:error, failed}
  end

  # The unique index decides a race between the lookup and the insert: the
  # loser re-reads the winner and gets the same answer as a later caller.
  defp insert_link(changeset, user_id, key) do
    case changeset |> put_change(:user_id, user_id) |> Repo.insert(@unlogged) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, failed} ->
        cond do
          identity_taken?(failed) -> owner_of(key, user_id)
          error_on?(failed, :user_id) -> {:error, :not_found}
          true -> {:error, failed}
        end
    end
  end

  defp owner_of(key, user_id) do
    case Repo.get_by(Identity, key, @unlogged) do
      %Identity{user_id: ^user_id} = identity -> {:ok, identity}
      # Owned by someone else, or removed again in the meantime.
      _other -> {:error, :conflict}
    end
  end

  defp identity_key(provider, subject) do
    with {:ok, changeset} <- validated_changeset(provider, subject) do
      {:ok, changeset |> apply_changes() |> Map.take([:provider, :provider_subject])}
    end
  end

  defp validated_changeset(provider, subject) do
    changeset = Identity.changeset(%Identity{}, %{provider: provider, provider_subject: subject})
    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp identity_taken?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, opts}} ->
      field == :provider_subject and opts[:constraint] == :unique
    end)
  end

  defp error_on?(changeset, field), do: Keyword.has_key?(changeset.errors, field)

  ## Account registration (ADR 0016)

  @doc """
  The user's shared account registration: profile (or `nil`), consent state,
  derived status (`:not_started`, `:in_progress`, `:complete`) and the
  missing requirements. Authentication never completes it: every user,
  however they signed in, registers the same way.
  """
  @spec get_account_registration(User.t()) :: Registration.t()
  defdelegate get_account_registration(user), to: Registration, as: :get

  @doc """
  Saves registration progress (`full_name`, `date_of_birth`, `accept_terms`,
  `accept_privacy`, `product_news`). A save with nothing to persist creates
  nothing; an invalid one changes nothing.
  """
  @spec update_account_registration(User.t(), map()) ::
          {:ok, Registration.t()} | validation_error()
  defdelegate update_account_registration(user, attrs), to: Registration, as: :update

  @doc "Completes account registration once every requirement is met."
  @spec complete_account_registration(User.t()) :: {:ok, Registration.t()} | validation_error()
  defdelegate complete_account_registration(user), to: Registration, as: :complete

  @doc """
  Whether the user has completed account registration. Role contexts use it
  for their own invariants (Fighter onboarding completion requires it).
  """
  @spec registration_complete?(User.t()) :: boolean()
  defdelegate registration_complete?(user), to: Registration, as: :complete?
end
