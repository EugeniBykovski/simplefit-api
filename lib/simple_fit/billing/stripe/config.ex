defmodule SimpleFit.Billing.Stripe.Config do
  @moduledoc """
  The Stripe configuration contract (SF-102; `config :simple_fit,
  SimpleFit.Billing.Stripe`). Read from the environment only in
  `config/runtime.exs` through `parse!/2`; documented in `.env.example`.

  * `:enabled` - `STRIPE_BILLING_ENABLED` (default `false`). Off means the
    integration is disabled: no checkout, portal or webhook processing, and
    no successful payment is ever substituted.
  * `:mode` - `STRIPE_MODE`, `test` (default) or `live`. Every key must
    belong to the mode, every object Stripe returns must carry the mode's
    `livemode`, and every stored row names its mode. Live mode is refused
    outside a production build and needs `STRIPE_LIVE_APPROVAL` (the release
    approval reference).
  * `:secret_key` - `STRIPE_SECRET_KEY` (`sk_`/`rk_` of the mode). Server
    side only; never logged, never sent to a client.
  * `:webhook_secret` - `STRIPE_WEBHOOK_SECRET` (`whsec_`), per endpoint.
  * `:account_id` - `STRIPE_ACCOUNT_ID` (`acct_`), the platform account the
    keys must belong to (checked by `mix billing.stripe status`).
  * `:api_version` - pinned to `2026-10-28.endive` (ADR 0026 SF-102);
    `STRIPE_API_VERSION` may name another dated, non-preview version.
  * `:portal_configuration_id` - `STRIPE_PORTAL_CONFIGURATION_ID` (`bpc_`),
    created by `mix billing.stripe setup-portal`; without it no portal
    session is created.
  * `:connect_enabled` - `STRIPE_CONNECT_ENABLED` (default `false`): only
    lets operators link and sync connected accounts. No member payment is
    ever created (merchant of record, KYB and fees are unapproved).

  No publishable key is read: hosted Checkout and the Customer Portal need
  none, and a secret never reaches a `NEXT_PUBLIC_*` variable.
  """

  @pinned_version "2026-10-28.endive"
  @key %{
    test: ~r/\A(sk|rk)_test_[A-Za-z0-9]{8,250}\z/,
    live: ~r/\A(sk|rk)_live_[A-Za-z0-9]{8,250}\z/
  }

  @type mode :: :test | :live
  @type t :: %{
          mode: mode(),
          secret_key: String.t(),
          webhook_secret: String.t() | nil,
          account_id: String.t() | nil,
          api_version: String.t(),
          portal_configuration_id: String.t() | nil,
          connect_enabled: boolean(),
          webhook_tolerance: pos_integer(),
          checkout_ttl: pos_integer(),
          req_options: keyword()
        }

  @doc "The pinned Stripe API version."
  @spec pinned_version() :: String.t()
  def pinned_version, do: @pinned_version

  @doc """
  The integration's state: `:disabled` (switched off), `{:misconfigured,
  missing}` (switched on without a required value: fails closed) or
  `{:ready, config}`.
  """
  @spec status() :: :disabled | {:misconfigured, [atom()]} | {:ready, t()}
  def status do
    env = Application.get_env(:simple_fit, SimpleFit.Billing.Stripe, [])

    cond do
      env[:enabled] != true -> :disabled
      (missing = missing(env)) != [] -> {:misconfigured, missing}
      true -> {:ready, ready(env)}
    end
  end

  # Fails closed: a key of another mode, or live mode without its approval.
  defp missing(env) do
    case Enum.reject([:secret_key, :mode], &present?(env[&1])) do
      [] -> mismatched(env)
      missing -> missing
    end
  end

  defp mismatched(env) do
    cond do
      not key_matches?(env[:secret_key], env[:mode]) -> [:secret_key]
      env[:mode] == :live and not present?(env[:live_approval]) -> [:live_approval]
      true -> []
    end
  end

  defp ready(env) do
    %{
      mode: env[:mode],
      secret_key: env[:secret_key],
      webhook_secret: env[:webhook_secret],
      account_id: env[:account_id],
      api_version: env[:api_version] || @pinned_version,
      portal_configuration_id: env[:portal_configuration_id],
      connect_enabled: env[:connect_enabled] == true,
      webhook_tolerance: env[:webhook_tolerance] || 300,
      checkout_ttl: env[:checkout_ttl] || 3600,
      req_options: env[:req_options] || []
    }
  end

  @doc "The ready configuration, or `{:error, :configuration_error}` (fail closed)."
  @spec fetch() :: {:ok, t()} | {:error, :configuration_error}
  def fetch do
    case status() do
      {:ready, config} -> {:ok, config}
      _ -> {:error, :configuration_error}
    end
  end

  @doc "The configured mode when ready, otherwise `nil`."
  @spec mode() :: mode() | nil
  def mode do
    case status() do
      {:ready, %{mode: mode}} -> mode
      _ -> nil
    end
  end

  @doc """
  Parses the Stripe environment variables for `config/runtime.exs`. `env`
  is a map of variable names to values (unset/blank already `nil`) and
  `build` the Mix environment. Raises on a malformed or contradictory value
  (a key of the other mode, live mode without approval or outside
  production), so a deployment mistake fails boot instead of charging.
  """
  @spec parse!(%{optional(String.t()) => String.t() | nil}, atom()) :: keyword()
  def parse!(env, build) do
    enabled = boolean!(env["STRIPE_BILLING_ENABLED"], "STRIPE_BILLING_ENABLED")
    mode = mode!(env["STRIPE_MODE"])
    secret = env["STRIPE_SECRET_KEY"]

    if mode == :live and build != :prod,
      do: raise(ArgumentError, "STRIPE_MODE=live is refused outside a production build")

    if mode == :live and enabled and blank?(env["STRIPE_LIVE_APPROVAL"]),
      do: raise(ArgumentError, "STRIPE_MODE=live needs STRIPE_LIVE_APPROVAL (a release approval)")

    if secret && not key_matches?(secret, mode),
      do: raise(ArgumentError, "STRIPE_SECRET_KEY does not belong to STRIPE_MODE=#{mode}")

    [
      enabled: enabled,
      mode: mode,
      secret_key: secret,
      webhook_secret:
        format!(
          env["STRIPE_WEBHOOK_SECRET"],
          ~r/\Awhsec_[A-Za-z0-9]{8,250}\z/,
          "STRIPE_WEBHOOK_SECRET"
        ),
      account_id:
        format!(env["STRIPE_ACCOUNT_ID"], ~r/\Aacct_[A-Za-z0-9]{1,250}\z/, "STRIPE_ACCOUNT_ID"),
      api_version:
        format!(
          env["STRIPE_API_VERSION"],
          ~r/\A\d{4}-\d{2}-\d{2}\.[a-z]+\z/,
          "STRIPE_API_VERSION"
        ) ||
          @pinned_version,
      portal_configuration_id:
        format!(
          env["STRIPE_PORTAL_CONFIGURATION_ID"],
          ~r/\Abpc_[A-Za-z0-9]{1,250}\z/,
          "STRIPE_PORTAL_CONFIGURATION_ID"
        ),
      connect_enabled: boolean!(env["STRIPE_CONNECT_ENABLED"], "STRIPE_CONNECT_ENABLED"),
      live_approval: env["STRIPE_LIVE_APPROVAL"]
    ]
  end

  @doc "Whether `key` is a secret or restricted key of `mode`."
  @spec key_matches?(term(), term()) :: boolean()
  def key_matches?(key, mode) when is_binary(key) and mode in [:test, :live],
    do: Regex.match?(@key[mode], key)

  def key_matches?(_key, _mode), do: false

  defp boolean!(nil, _name), do: false
  defp boolean!(value, _name) when value in ~w(true 1), do: true
  defp boolean!(value, _name) when value in ~w(false 0), do: false
  defp boolean!(_value, name), do: raise(ArgumentError, "#{name} must be true/false/1/0")

  defp mode!(nil), do: :test
  defp mode!("test"), do: :test
  defp mode!("live"), do: :live
  defp mode!(_), do: raise(ArgumentError, "STRIPE_MODE must be test or live")

  defp format!(nil, _pattern, _name), do: nil

  defp format!(value, pattern, name) do
    if Regex.match?(pattern, value), do: value, else: raise(ArgumentError, "#{name} is malformed")
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value)

  defp blank?(value), do: not present?(value)
end
