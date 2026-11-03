defmodule Mix.Tasks.Billing.Stripe do
  @shortdoc "Operator tasks of the Stripe integration (status, prices, portal, refunds, Connect)"

  @moduledoc """
  Operator tasks of SimpleFit's Stripe integration (SF-102;
  `SimpleFit.Billing.Operations`). Nothing here is reachable over HTTP; each
  write names the operator and is audited. Output holds ids, modes and
  statuses only: never a key, a secret, a URL or a person's data.

      $ mix billing.stripe status
      $ mix billing.stripe webhook-events
      $ mix billing.stripe map-price PRICE_VERSION_ID --operator NAME
      $ mix billing.stripe setup-portal --operator NAME
      $ mix billing.stripe refund STRIPE_INVOICE_ID --operator NAME --approval REF [--reason REASON]
      $ mix billing.stripe reconcile SUBSCRIPTION_ID
      $ mix billing.stripe link-account GYM_ID ACCOUNT_ID --operator NAME
      $ mix billing.stripe sync-account ACCOUNT_ID

  * `status` - whether the integration is disabled, misconfigured (which
    setting is missing) or ready, its mode and pinned API version.
  * `webhook-events` - the event types to enable on the Stripe endpoint.
  * `map-price` - creates the Stripe Product/Price of a fixed SF-101 price
    version in the configured mode (live: published, non-provisional only).
  * `setup-portal` - creates the Customer Portal configuration and prints
    its id for `STRIPE_PORTAL_CONFIGURATION_ID`.
  * `refund` - a full refund of a paid invoice under an approval reference
    (partial refunds are not approved). `--reason`: `duplicate`,
    `fraudulent` or `requested_by_customer`.
  * `reconcile` - reconciles one SF-101 subscription with Stripe now.
  * `link-account`, `sync-account` - Stripe Connect foundation, test mode
    only and with `STRIPE_CONNECT_ENABLED=true`; never a payment.
  """

  use Mix.Task

  alias SimpleFit.Billing.{Operations, Reconciliation, Webhooks}
  alias SimpleFit.Billing.Stripe.Config

  @switches [operator: :string, approval: :string, reason: :string]
  @reasons ~w(duplicate fraudulent requested_by_customer)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)

    command(rest, opts)
  end

  defp command(["status"], _opts), do: status()

  defp command(["webhook-events"], _opts),
    do: Enum.each(Webhooks.handled_types(), &Mix.shell().info(&1))

  defp command(["map-price", id], opts) do
    report(Operations.map_price(id, operator!(opts)), fn m ->
      "mapped: #{m.price_version_id} -> #{m.stripe_price_id} (#{m.mode}, #{m.amount_minor} #{m.currency}/#{m.interval})"
    end)
  end

  defp command(["setup-portal"], opts),
    do: report(Operations.setup_portal(operator!(opts)), &"portal configuration: #{&1}")

  defp command(["refund", invoice_id], opts), do: refund(invoice_id, opts)

  defp command(["reconcile", id], _opts),
    do: Mix.shell().info("reconcile: #{inspect(Reconciliation.reconcile_subscription(id))}")

  defp command(["link-account", gym_id, account_id], opts) do
    report(
      Operations.link_connected_account(gym_id, account_id, operator!(opts)),
      &"linked: #{&1.stripe_account_id} (charges #{&1.charges_enabled}, payouts #{&1.payouts_enabled})"
    )
  end

  defp command(["sync-account", account_id], _opts) do
    report(
      Operations.sync_connected_account(account_id),
      &"synced: #{&1.stripe_account_id} (charges #{&1.charges_enabled}, payouts #{&1.payouts_enabled}, due #{&1.requirements_due_count})"
    )
  end

  defp command(_rest, _opts) do
    Mix.raise(
      "usage: mix billing.stripe status|webhook-events|map-price|setup-portal|refund|reconcile|link-account|sync-account (see mix help billing.stripe)"
    )
  end

  defp status do
    case Config.status() do
      :disabled ->
        Mix.shell().info("stripe: disabled")

      {:misconfigured, missing} ->
        Mix.shell().info("stripe: misconfigured (missing: #{Enum.join(missing, ", ")})")

      {:ready, config} ->
        Mix.shell().info(
          "stripe: ready (mode #{config.mode}, api #{config.api_version}, webhook secret #{present(config.webhook_secret)}, portal #{present(config.portal_configuration_id)}, connect #{config.connect_enabled})"
        )
    end
  end

  defp refund(invoice_id, opts) do
    approval = opts[:approval] || Mix.raise("--approval REF is required")
    reason = opts[:reason]

    if reason && reason not in @reasons,
      do: Mix.raise("--reason must be one of #{Enum.join(@reasons, ", ")}")

    report(
      Operations.refund(invoice_id, operator!(opts), approval, reason: reason),
      &"refund #{&1.id}: #{&1.status} (#{&1.amount_minor} #{&1.currency})"
    )
  end

  defp present(nil), do: "missing"
  defp present(_), do: "set"

  defp operator!(opts), do: opts[:operator] || Mix.raise("--operator NAME is required")

  defp report({:ok, value}, format), do: Mix.shell().info(format.(value))
  defp report({:error, reason}, _format), do: Mix.raise("refused: #{inspect(reason)}")
end
