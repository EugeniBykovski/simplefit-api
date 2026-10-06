defmodule SimpleFit.Accounts.ProviderAccounts do
  @moduledoc """
  The user behind a verified provider subject (SF-19, ADR 0009), shared by
  the provider sign-ins (Google, ADR 0013; Apple, ADR 0014). Internal to
  `SimpleFit.Accounts`.

  Resolve first; register on a miss. Concurrent first sign-ins race on the
  SF-19 unique index: `register_user/2` is atomic (user and identity, or
  neither), and the loser resolves the winner's user, so no orphan or
  duplicate user is left. Nothing is ever matched by email.
  """

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User

  @spec resolve_or_register(Accounts.provider_input(), String.t()) ::
          {:ok, User.t(), :created | :existing} | {:error, :unauthorized | :unavailable}
  def resolve_or_register(provider, subject) do
    case Accounts.resolve_user(provider, subject) do
      {:ok, %User{} = user} ->
        {:ok, user, :existing}

      {:error, :not_found} ->
        case Accounts.register_user(provider, subject) do
          {:ok, user} -> {:ok, user, :created}
          {:error, :conflict} -> resolve_winner(provider, subject)
          {:error, _changeset} -> {:error, :unauthorized}
        end

      {:error, _changeset} ->
        {:error, :unauthorized}
    end
  end

  defp resolve_winner(provider, subject) do
    case Accounts.resolve_user(provider, subject) do
      {:ok, user} -> {:ok, user, :existing}
      _gone -> {:error, :unavailable}
    end
  end
end
