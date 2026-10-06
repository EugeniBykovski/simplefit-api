defmodule SimpleFit.Accounts.AppleAuth do
  @moduledoc """
  Sign in with Apple (ADR 0014). Called through `SimpleFit.Accounts`;
  internal to the context.

      Apple identity token + raw nonce
        → SimpleFit.Identity.verify(:apple, ...)   (signature, iss, aud, time, sub, nonce)
        → Identity(provider: :apple, provider_subject: sub)
        → resolve the user, or register a new one (SF-19)
        → SimpleFit session (SF-20)

  * The Apple `sub` is the only identity key. SimpleFit requests no Apple
    scopes, and email (including private relay addresses), name and the
    other claims are never read, so nothing can be overwritten on later
    sign-ins and an email identity with the same address is never linked or
    merged (ADR 0009).
  * Concurrent first sign-ins resolve to one user
    (`SimpleFit.Accounts.ProviderAccounts`). Every request gets its own
    session.
  * The Apple token and nonce are never stored, logged or used after
    verification.

  Limits (`SimpleFit.RateLimit`): 30 requests per client IP per 10 minutes
  before verification, and 20 per verified Apple subject per 10 minutes
  after it (keyed by an HMAC of the subject, never by an unverified claim).
  """

  require Logger

  alias SimpleFit.Accounts.EmailAuth.Secrets
  alias SimpleFit.Accounts.{ProviderAccounts, Sessions}
  alias SimpleFit.{Identity, RateLimit}

  @ip_rule {"apple_auth:ip", 30, 600}
  @subject_rule {"apple_auth:subject", 20, 600}

  # The raw nonce: 32..128 URL-safe characters (the clients send 43, the
  # base64url form of 32 random bytes).
  @nonce ~r/\A[A-Za-z0-9_-]{32,128}\z/

  @typedoc "A successful Apple sign-in."
  @type result :: %{credentials: Sessions.credentials(), account: :created | :existing}

  @typedoc "An expected failure."
  @type error ::
          {:error, Ecto.Changeset.t()}
          | {:error, {:rate_limited, pos_integer()}}
          | {:error, :unauthorized | :unavailable}

  @doc "Signs in with an Apple identity token, creating the account on first use."
  @spec authenticate(term(), term(), String.t()) :: {:ok, result()} | error()
  def authenticate(id_token, nonce, client_ip) do
    with {:ok, credential} <- validate(id_token, nonce),
         :ok <- limit(@ip_rule, client_ip),
         {:ok, %{subject: subject}} <- verify(credential),
         :ok <- limit(@subject_rule, "apple:" <> subject),
         {:ok, user, account} <- ProviderAccounts.resolve_or_register(:apple, subject),
         {:ok, credentials} <- Sessions.create(user) do
      emit(:verified, %{account: account})
      {:ok, %{credentials: credentials, account: account}}
    end
  end

  defp validate(id_token, nonce) do
    changeset =
      {%{}, %{id_token: :string, nonce: :string}}
      |> Ecto.Changeset.change()
      |> require_field(:id_token, is_binary(id_token) and byte_size(id_token) > 0)
      |> require_nonce(nonce)

    if changeset.valid?,
      do: {:ok, %{id_token: id_token, nonce: nonce}},
      else: {:error, changeset}
  end

  defp require_field(changeset, _field, true), do: changeset

  defp require_field(changeset, field, false),
    do: Ecto.Changeset.add_error(changeset, field, "can't be blank", validation: :required)

  defp require_nonce(changeset, nonce) when is_binary(nonce) and nonce != "" do
    if Regex.match?(@nonce, nonce),
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :nonce, "has invalid format", validation: :format)
  end

  defp require_nonce(changeset, _nonce), do: require_field(changeset, :nonce, false)

  defp verify(credential) do
    case Identity.verify(:apple, credential) do
      {:ok, verified} ->
        {:ok, verified}

      {:error, {:rejected, reason}} ->
        emit(:rejected, %{reason: reason})
        {:error, :unauthorized}

      {:error, reason} when reason in [:unavailable, :not_configured] ->
        # The client only sees service_unavailable; the bounded reason makes
        # the cause (e.g. APPLE_SIGN_IN_CLIENT_IDS unset) visible in the logs.
        Logger.warning("apple sign-in unavailable", reason: reason)
        emit(:unavailable, %{reason: reason})
        {:error, :unavailable}
    end
  end

  defp limit({bucket, limit, period}, value) do
    case RateLimit.hit([{bucket, Secrets.rate_limit_key(bucket, value), limit, period}]) do
      :ok ->
        :ok

      {:error, {:rate_limited, _seconds}} = limited ->
        emit(:rate_limited, %{})
        limited
    end
  end

  defp emit(event, metadata),
    do: :telemetry.execute([:simple_fit, :auth, :apple, event], %{count: 1}, metadata)
end
