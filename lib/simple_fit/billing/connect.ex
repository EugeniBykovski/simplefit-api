defmodule SimpleFit.Billing.Connect do
  @moduledoc """
  The Stripe Connect foundation for gym member payments (SF-102). Gym
  member payments are a separate financial flow from SimpleFit's SaaS
  billing: the payer is a member, the seller the gym (Direct Charges on the
  gym's connected account are the candidate model). Its essential decisions
  are **not approved** (merchant of record, connected account type and
  capabilities, country availability, legal seller identity, KYB/KYC,
  platform fees and their currency, refund/dispute and negative-balance
  liability, tax responsibility, payouts, offboarding), so:

  * no code creates a connected account, an onboarding link, a charge, a
    transfer or a payout, and no SaaS setting enables any of it;
  * an operator may link an **existing test-mode** account to a gym
    (`STRIPE_CONNECT_ENABLED=true`, `mix billing.stripe link-account`) to
    verify the mapping, and its capability summary is synced from Stripe
    (never from a redirect or a client);
  * `member_payments/1` answers why member payments are unavailable; it is
    always `{:unavailable, reasons}` until those decisions are approved and
    a ticket implements them.

  Each gym has at most one account per mode and an account belongs to one
  gym (unique indexes): one gym's customers can never be attached to another
  gym's account. No KYC document or personal data is stored.
  """

  alias SimpleFit.Billing.Stripe.{Client, Config, ConnectedAccount}
  alias SimpleFit.{Clock, Repo}
  alias SimpleFit.Gyms.Gym

  @unlogged [log: false]

  @unresolved [
    :merchant_of_record,
    :account_type,
    :kyb,
    :platform_fees,
    :refund_dispute_liability,
    :tax_responsibility,
    :payouts
  ]

  @doc "Why gym member payments are unavailable (always, until approved)."
  @spec member_payments(term()) :: {:unavailable, [atom()]}
  def member_payments(_gym_id), do: {:unavailable, @unresolved}

  @doc """
  Links an existing Stripe connected account to a gym (operator, test mode
  only, Connect enabled), after reading it from Stripe.
  """
  @spec link(term(), String.t(), String.t()) ::
          {:ok, ConnectedAccount.t()}
          | {:error, :not_found | {:conflict, map()} | SimpleFit.Provider.error()}
  def link(gym_id, account_id, operator) when is_binary(operator) and operator != "" do
    with {:ok, config} <- enabled(),
         {:ok, gym} <- gym(gym_id),
         {:ok, account} <- fetch(account_id) do
      %ConnectedAccount{
        mode: config.mode,
        gym_id: gym.id,
        stripe_account_id: account.id,
        linked_by: operator,
        last_synced_at: Clock.utc_now()
      }
      |> Ecto.Changeset.change(summary(account))
      |> Ecto.Changeset.unique_constraint([:mode, :gym_id],
        name: :stripe_connected_accounts_mode_gym_id_index
      )
      |> Ecto.Changeset.unique_constraint([:mode, :stripe_account_id],
        name: :stripe_connected_accounts_mode_stripe_account_id_index
      )
      |> Repo.insert(@unlogged)
      |> case do
        {:ok, linked} -> {:ok, linked}
        {:error, _} -> {:error, {:conflict, %{connected_account: "already_linked"}}}
      end
    end
  end

  @doc "Refreshes a linked account's capability summary from Stripe."
  @spec sync(String.t()) ::
          {:ok, ConnectedAccount.t()} | {:error, :not_found | SimpleFit.Provider.error()}
  def sync(account_id) do
    with {:ok, config} <- Config.fetch(),
         %ConnectedAccount{} = linked <-
           Repo.get_by(
             ConnectedAccount,
             [mode: config.mode, stripe_account_id: account_id],
             @unlogged
           ) ||
             {:error, :not_found},
         {:ok, account} <- fetch(account_id) do
      {:ok,
       linked
       |> Ecto.Changeset.change(Map.put(summary(account), :last_synced_at, Clock.utc_now()))
       |> Repo.update!(@unlogged)}
    end
  end

  defp enabled do
    case Config.fetch() do
      {:ok, %{connect_enabled: true, mode: :test} = config} -> {:ok, config}
      {:ok, %{connect_enabled: true}} -> {:error, {:conflict, %{connect: "live_not_approved"}}}
      {:ok, _} -> {:error, {:conflict, %{connect: "disabled"}}}
      error -> error
    end
  end

  defp gym(gym_id) do
    with {:ok, id} <- Ecto.UUID.cast(gym_id),
         %Gym{} = gym <- Repo.get(Gym, id, @unlogged) do
      {:ok, gym}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch(account_id),
    do: Client.get("/v1/accounts/#{Client.id!(account_id, "acct")}", %{}, :account)

  defp summary(account),
    do:
      Map.take(account, [
        :charges_enabled,
        :payouts_enabled,
        :details_submitted,
        :requirements_due_count,
        :disabled_reason
      ])
end
