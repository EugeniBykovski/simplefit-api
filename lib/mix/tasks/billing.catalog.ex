defmodule Mix.Tasks.Billing.Catalog do
  @shortdoc "Operator workflow for the SimpleFit SaaS plan catalog (drafts, publication)"

  @moduledoc """
  The operator workflow of `SimpleFit.Billing.Catalog` (SF-101). SaaS plans
  are SimpleFit's product: no HTTP endpoint writes them, and nothing is offered to
  gyms until a version is published.

  **A production build refuses every command but `list`** (SF-138,
  `SimpleFit.Billing.OperatorCommands`): nothing proves who typed `--operator` or
  `--approval`, and neither is a pricing approval. Elsewhere they are labels in the
  audit trail.

      $ mix billing.catalog list [PLAN_KEY]
      $ mix billing.catalog seed-provisional --operator NAME
      $ mix billing.catalog publish VERSION_ID --approval REF --operator NAME [--confirm-provisional]
      $ mix billing.catalog retire VERSION_ID --operator NAME

  `seed-provisional` writes the SF-101 provisional catalog (Starter, Growth,
  Pro, Enterprise in PLN) as drafts only. Publishing provisional prices needs
  `--confirm-provisional` as well as an approval reference. It prints ids,
  statuses and prices; never a person's data.
  """

  use Mix.Task

  alias SimpleFit.Billing.{Catalog, OperatorCommands, PlanVersion}
  alias SimpleFit.Money

  @switches [operator: :string, approval: :string, confirm_provisional: :boolean]
  @privileged ~w(seed-provisional publish retire)

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)

    # Before anything starts: nothing to connect to or read.
    if List.first(rest) in @privileged, do: OperatorCommands.ensure_available!()

    Mix.Task.run("app.start")

    case rest do
      ["list"] ->
        list(nil)

      ["list", key] ->
        list(key)

      ["seed-provisional"] ->
        report(Catalog.seed_provisional(operator!(opts)), &"drafted: #{Enum.join(&1, ", ")}")

      ["publish", id] ->
        publish(id, opts)

      ["retire", id] ->
        report(Catalog.retire(id, operator!(opts)), &describe/1)

      _ ->
        Mix.raise(
          "usage: mix billing.catalog list|seed-provisional|publish|retire (see mix help billing.catalog)"
        )
    end
  end

  defp publish(id, opts) do
    approval = opts[:approval] || Mix.raise("--approval REF is required")
    confirm = Keyword.get(opts, :confirm_provisional, false)

    report(
      Catalog.publish(id, approval, operator!(opts), confirm_provisional: confirm),
      &describe/1
    )
  end

  defp list(nil) do
    for key <- ~w(starter growth pro enterprise),
        version <- Catalog.versions(key),
        do: Mix.shell().info(describe(version))
  end

  defp list(key),
    do: for(version <- Catalog.versions(key), do: Mix.shell().info(describe(version)))

  defp operator!(opts), do: opts[:operator] || Mix.raise("--operator NAME is required")

  defp report({:ok, value}, format), do: Mix.shell().info(format.(value))
  defp report({:error, reason}, _format), do: Mix.raise("refused: #{inspect(reason)}")

  defp describe(%PlanVersion{} = v) do
    prices =
      Enum.map_join(v.prices, ", ", fn
        %{pricing: :quote_required, interval: i, currency: c} -> "#{i} #{c} quote"
        %{amount_minor: m, interval: i, currency: c} -> "#{i} #{Money.format(m, c)} #{c}"
      end)

    "#{v.plan.key} v#{v.version} #{v.status} (#{v.price_source}) #{v.id} [#{prices}]"
  end
end
