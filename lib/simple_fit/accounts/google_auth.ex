defmodule SimpleFit.Accounts.GoogleAuth do
  @moduledoc """
  Google sign-in (ADR 0013). Called through `SimpleFit.Accounts`; internal to
  the context.

      Google ID token
        → SimpleFit.Identity.verify(:google, token)   (signature, iss, aud, azp, time, sub)
        → Identity(provider: :google, provider_subject: sub)
        → resolve the user, or register a new one (SF-19)
        → SimpleFit session (SF-20)

  * The Google `sub` is the only identity key. Email, name and picture
    claims are never read, so an email identity with the same address is
    never linked or merged: an unknown `sub` is always a new user (ADR
    0009). Linking accounts is a future, explicitly authenticated flow.
  * Concurrent first sign-ins race on the SF-19 unique index:
    `register_user/2` is atomic (user and identity, or neither), and the
    loser resolves the winner's user. Every request gets its own session.
  * The Google token is never stored, logged or used after verification.

  Limits (`SimpleFit.RateLimit`): 30 requests per client IP per 10 minutes
  before verification, and 20 per verified Google subject per 10 minutes
  after it (keyed by an HMAC of the subject, never by an unverified claim).
  """

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.EmailAuth.Secrets
  alias SimpleFit.Accounts.{Sessions, User}
  alias SimpleFit.{Identity, RateLimit}

  @ip_rule {"google_auth:ip", 30, 600}
  @subject_rule {"google_auth:subject", 20, 600}

  @typedoc "A successful Google sign-in."
  @type result :: %{credentials: Sessions.credentials(), account: :created | :existing}

  @typedoc "An expected failure."
  @type error ::
          {:error, Ecto.Changeset.t()}
          | {:error, {:rate_limited, pos_integer()}}
          | {:error, :unauthorized | :unavailable}

  @doc "Signs in with a Google ID token, creating the account on first use."
  @spec authenticate(term(), String.t()) :: {:ok, result()} | error()
  def authenticate(id_token, client_ip) do
    with {:ok, token} <- validate(id_token),
         :ok <- limit(@ip_rule, client_ip),
         {:ok, %{subject: subject}} <- verify(token),
         :ok <- limit(@subject_rule, "google:" <> subject),
         {:ok, user, account} <- resolve_or_register(subject),
         {:ok, credentials} <- Sessions.create(user) do
      emit(:verified, %{account: account})
      {:ok, %{credentials: credentials, account: account}}
    end
  end

  defp validate(token) when is_binary(token) and byte_size(token) > 0, do: {:ok, token}

  defp validate(_token) do
    {:error,
     {%{}, %{id_token: :string}}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:id_token, "can't be blank", validation: :required)}
  end

  defp verify(token) do
    case Identity.verify(:google, token) do
      {:ok, verified} ->
        {:ok, verified}

      {:error, {:rejected, reason}} ->
        emit(:rejected, %{reason: reason})
        {:error, :unauthorized}

      {:error, reason} when reason in [:unavailable, :not_configured] ->
        emit(:unavailable, %{reason: reason})
        {:error, :unavailable}
    end
  end

  # SF-19: resolve first; register on a miss; a concurrent registration that
  # wins the unique index is resolved instead (no orphan user is left).
  defp resolve_or_register(subject) do
    case Accounts.resolve_user(:google, subject) do
      {:ok, %User{} = user} ->
        {:ok, user, :existing}

      {:error, :not_found} ->
        case Accounts.register_user(:google, subject) do
          {:ok, user} -> {:ok, user, :created}
          {:error, :conflict} -> resolve_winner(subject)
          {:error, _changeset} -> {:error, :unauthorized}
        end

      {:error, _changeset} ->
        {:error, :unauthorized}
    end
  end

  defp resolve_winner(subject) do
    case Accounts.resolve_user(:google, subject) do
      {:ok, user} -> {:ok, user, :existing}
      _gone -> {:error, :unavailable}
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
    do: :telemetry.execute([:simple_fit, :auth, :google, event], %{count: 1}, metadata)
end
