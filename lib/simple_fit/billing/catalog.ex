defmodule SimpleFit.Billing.Catalog do
  @moduledoc """
  The SimpleFit SaaS plan catalog (SF-101): an operator workflow, not a
  gym's. Plans are SimpleFit's product, so there is no HTTP endpoint that
  writes them; operators run these functions (through the
  `billing.catalog.*` Mix tasks), and every change is a `billing_audit_events`
  row in the same transaction, naming the operator.

  * A plan has at most one draft and one published version. A draft is
    edited in place (name, description, trial proposal, prices,
    entitlements), archived and restored, or published.
  * Publishing needs an approval reference (a decision or ticket) and at
    least one price; a draft whose prices are `provisional` is published
    only with an explicit confirmation that they were approved as such. The
    previous published version becomes `superseded`: it stays immutable and
    keeps its subscriptions.
  * Prices are integer minor units in a supported currency, or
    `quote_required` with no amount (Enterprise). Zero is a price (free); a
    missing price is not.
  * Entitlements name registry keys only (`SimpleFit.Entitlements.Features`).

  `seed_provisional/1` writes the provisional catalog the product owner
  authorized for SF-101 as drafts only: nothing is offered until a version
  is published through `publish/4`.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Billing.{AuditEvent, Plan, PlanEntitlement, PlanVersion, PriceVersion}
  alias SimpleFit.{Clock, Money, Repo}
  alias SimpleFit.Entitlements.Features

  @unlogged [log: false]

  # The provisional SaaS catalog (SF-101 brief, PLN, Polish market): no
  # approved design or product decision priced SimpleFit plans (D-G09).
  # Drafts only; the trial is a proposal, never started.
  @provisional [
    {"starter", "Starter", "1490", "149"},
    {"growth", "Growth", "3490", "349"},
    {"pro", "Pro", "6990", "699"},
    {"enterprise", "Enterprise", :quote, :quote}
  ]

  @type error :: :not_found | {:conflict, map()} | Changeset.t()

  ## Reads

  @doc "The published catalog: each plan's published version with its prices and entitlements."
  @spec published() :: [PlanVersion.t()]
  def published do
    Repo.all(
      from(v in PlanVersion,
        join: p in assoc(v, :plan),
        where: v.status == :published,
        order_by: [asc: p.key],
        preload: [plan: p, prices: ^prices_order(), entitlements: ^entitlements_order()]
      ),
      @unlogged
    )
  end

  @doc "Every version of the plan `key`, newest first (operators)."
  @spec versions(String.t()) :: [PlanVersion.t()]
  def versions(key) do
    Repo.all(
      from(v in PlanVersion,
        join: p in assoc(v, :plan),
        where: p.key == ^key,
        order_by: [desc: v.version],
        preload: [plan: p, prices: ^prices_order(), entitlements: ^entitlements_order()]
      ),
      @unlogged
    )
  end

  @doc "One plan version with its plan, prices and entitlements."
  @spec get_version(term()) :: {:ok, PlanVersion.t()} | {:error, :not_found}
  def get_version(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %PlanVersion{} = version <- Repo.get(PlanVersion, id, @unlogged) do
      {:ok,
       Repo.preload(version, [:plan, prices: prices_order(), entitlements: entitlements_order()])}
    else
      _ -> {:error, :not_found}
    end
  end

  ## Operator writes

  @doc """
  Creates a draft version of the plan `key` (creating the plan when it does
  not exist yet), numbered after the plan's latest version. `attrs`: `name`,
  `description`, `price_source` (`approved_design | product_decision |
  provisional`), `proposed_trial_days`, `prices` and `entitlements` (see the
  moduledoc). A plan holds one draft at a time (`409`).
  """
  @spec draft(String.t(), map(), String.t()) :: {:ok, PlanVersion.t()} | {:error, error()}
  def draft(key, attrs, actor) when is_binary(actor) and actor != "" do
    attrs = stringify(attrs)

    transaction(fn now ->
      with {:ok, plan} <- plan(key, actor, now),
           :ok <- no_draft(plan),
           {:ok, fields} <- version_fields(attrs),
           {:ok, prices} <- prices(attrs),
           {:ok, entitlements} <- entitlements(attrs) do
        version =
          Repo.insert!(
            struct!(
              PlanVersion,
              Map.merge(fields, %{plan_id: plan.id, version: next_version(plan), status: :draft})
            ),
            @unlogged
          )

        write_prices!(version, prices, entitlements)
        audit!(:saas_plan_version_drafted, actor, version, now, %{price_count: length(prices)})
        {:ok, reload(version)}
      end
    end)
  end

  @doc "Replaces a draft's content (name, description, trial proposal, prices, entitlements)."
  @spec update_draft(term(), map(), String.t()) :: {:ok, PlanVersion.t()} | {:error, error()}
  def update_draft(version_id, attrs, actor) when is_binary(actor) and actor != "" do
    attrs = stringify(attrs)

    transaction(fn now ->
      with {:ok, version} <- lock_version(version_id),
           :ok <- status(version, [:draft]),
           {:ok, fields} <- version_fields(attrs),
           {:ok, prices} <- prices(attrs),
           {:ok, entitlements} <- entitlements(attrs) do
        version = version |> Changeset.change(fields) |> Repo.update!(@unlogged)

        Repo.delete_all(
          from(p in PriceVersion, where: p.plan_version_id == ^version.id),
          @unlogged
        )

        Repo.delete_all(
          from(e in PlanEntitlement, where: e.plan_version_id == ^version.id),
          @unlogged
        )

        write_prices!(version, prices, entitlements)
        audit!(:saas_plan_version_updated, actor, version, now, %{price_count: length(prices)})
        {:ok, reload(version)}
      end
    end)
  end

  @doc "Archives a draft (never published); `restore/2` makes it the draft again."
  @spec archive(term(), String.t()) :: {:ok, PlanVersion.t()} | {:error, error()}
  def archive(version_id, actor), do: move(version_id, actor, [:draft], :archived)

  @doc "Restores an archived draft (it was never published; history is unchanged)."
  @spec restore(term(), String.t()) :: {:ok, PlanVersion.t()} | {:error, error()}
  def restore(version_id, actor), do: move(version_id, actor, [:archived], :draft)

  @doc """
  Publishes a draft under `approval_reference`. Options: `confirm_provisional:
  true` is required when the draft's prices are provisional. The previous
  published version becomes superseded. Concurrent publications of one plan
  serialize on the plan row; the second meets the outcome (`409`).
  """
  @spec publish(term(), String.t(), String.t(), keyword()) ::
          {:ok, PlanVersion.t()} | {:error, error()}
  def publish(version_id, approval_reference, actor, opts \\ [])
      when is_binary(actor) and actor != "" do
    transaction(fn now ->
      with {:ok, version} <- lock_version(version_id),
           :ok <- lock_plan(version.plan_id),
           {:ok, version} <- lock_version(version.id),
           :ok <- status(version, [:draft]),
           :ok <- approval(approval_reference),
           :ok <- provisional(version, opts),
           :ok <- priced(version) do
        supersede!(version.plan_id, now)

        version =
          version
          |> Changeset.change(
            status: :published,
            published_at: now,
            published_by: actor,
            approval_reference: String.trim(approval_reference)
          )
          |> Repo.update!(@unlogged)

        audit!(:saas_plan_version_published, actor, version, now, %{
          approval_reference: version.approval_reference
        })

        {:ok, reload(version)}
      end
    end)
  end

  @doc "Withdraws a published (or superseded) version from new subscriptions; existing ones keep it."
  @spec retire(term(), String.t()) :: {:ok, PlanVersion.t()} | {:error, error()}
  def retire(version_id, actor), do: move(version_id, actor, [:published, :superseded], :retired)

  @doc """
  Writes the SF-101 provisional catalog as drafts (Starter, Growth, Pro,
  Enterprise; PLN; a 14-day trial proposal; no entitlements). A plan that
  already has a version is left alone, so running it again changes nothing.
  Returns the plan keys that received a draft.
  """
  @spec seed_provisional(String.t()) :: {:ok, [String.t()]} | {:error, error()}
  def seed_provisional(actor) do
    Enum.reduce_while(@provisional, {:ok, []}, fn entry, {:ok, seeded} ->
      case seed_one(entry, actor) do
        {:ok, nil} -> {:cont, {:ok, seeded}}
        {:ok, key} -> {:cont, {:ok, seeded ++ [key]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp seed_one({key, name, annual, monthly}, actor) do
    if versions(key) == [] do
      with {:ok, _} <- draft(key, provisional_attrs(name, annual, monthly), actor),
           do: {:ok, key}
    else
      {:ok, nil}
    end
  end

  defp provisional_attrs(name, :quote, :quote),
    do: %{
      "name" => name,
      "description" => "Custom quote (provisional catalog, SF-101).",
      "price_source" => "provisional",
      "prices" => [
        %{"interval" => "month", "currency" => "PLN", "pricing" => "quote_required"},
        %{"interval" => "year", "currency" => "PLN", "pricing" => "quote_required"}
      ]
    }

  defp provisional_attrs(name, annual, monthly),
    do: %{
      "name" => name,
      "description" => "Provisional catalog price (SF-101), not an approved design value.",
      "price_source" => "provisional",
      "proposed_trial_days" => 14,
      "prices" => [
        %{"interval" => "month", "currency" => "PLN", "amount" => monthly},
        %{"interval" => "year", "currency" => "PLN", "amount" => annual}
      ]
    }

  ## Steps

  defp transaction(fun) do
    Repo.transaction(
      fn ->
        case fun.(Clock.utc_now()) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      @unlogged
    )
  rescue
    error in Ecto.ConstraintError -> {:error, {:conflict, %{saas_plan: constraint(error)}}}
  end

  defp constraint(%Ecto.ConstraintError{constraint: name}) do
    if String.contains?(name, "draft"), do: "draft_exists", else: "conflict"
  end

  defp move(version_id, actor, from, to) when is_binary(actor) and actor != "" do
    transaction(fn now ->
      with {:ok, version} <- lock_version(version_id),
           :ok <- status(version, from) do
        changes = %{status: to} |> Map.merge(stamp(to, now))
        version = version |> Changeset.change(changes) |> Repo.update!(@unlogged)
        audit!(event(to), actor, version, now, %{})
        {:ok, reload(version)}
      end
    end)
  end

  defp stamp(:archived, now), do: %{archived_at: now}
  defp stamp(:draft, _now), do: %{archived_at: nil}
  defp stamp(:retired, now), do: %{retired_at: now}

  defp event(:archived), do: :saas_plan_version_archived
  defp event(:draft), do: :saas_plan_version_restored
  defp event(:retired), do: :saas_plan_version_retired

  defp plan(key, actor, now) do
    case Repo.one(from(p in Plan, where: p.key == ^key, lock: "FOR UPDATE"), @unlogged) do
      %Plan{} = plan ->
        {:ok, plan}

      nil ->
        changeset =
          {%{key: nil}, %{key: :string}}
          |> Changeset.cast(%{key: key}, [:key])
          |> Changeset.validate_required([:key])
          |> Changeset.validate_format(:key, ~r/\A[a-z][a-z0-9_]{1,39}\z/)

        with {:ok, %{key: key}} <- Changeset.apply_action(changeset, :insert) do
          plan = Repo.insert!(%Plan{key: key}, @unlogged)
          audit!(:saas_plan_created, actor, %{plan_id: plan.id, id: nil}, now, %{})
          {:ok, plan}
        end
    end
  end

  defp no_draft(plan) do
    if Repo.exists?(from(v in PlanVersion, where: v.plan_id == ^plan.id and v.status == :draft)),
      do: {:error, {:conflict, %{saas_plan: "draft_exists"}}},
      else: :ok
  end

  defp next_version(plan),
    do:
      (Repo.one(from(v in PlanVersion, where: v.plan_id == ^plan.id, select: max(v.version))) ||
         0) + 1

  defp version_fields(attrs) do
    types = %{
      name: :string,
      description: :string,
      price_source: :string,
      proposed_trial_days: :integer
    }

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required([:name, :price_source])
    |> Changeset.validate_length(:name, min: 1, max: 80)
    |> Changeset.validate_length(:description, max: 500)
    |> Changeset.validate_inclusion(
      :price_source,
      Enum.map(PlanVersion.price_sources(), &to_string/1)
    )
    |> Changeset.validate_number(:proposed_trial_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 90
    )
    |> Changeset.apply_action(:validate)
    |> case do
      {:ok, fields} ->
        {:ok,
         %{
           name: fields.name,
           description: Map.get(fields, :description),
           price_source: String.to_existing_atom(fields.price_source),
           proposed_trial_days: Map.get(fields, :proposed_trial_days)
         }}

      error ->
        error
    end
  end

  # [%{"interval", "currency", "amount"} | %{"interval", "currency", "pricing" => "quote_required"}]
  defp prices(attrs) do
    rows = Map.get(attrs, "prices", [])

    rows
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case price(stringify(row)) do
        {:ok, price} -> {:cont, {:ok, acc ++ [price]}}
        {:error, code} -> {:halt, {:error, field_error(:prices, "price #{index}: #{code}", code)}}
      end
    end)
    |> unique_prices()
  end

  defp price(%{"interval" => interval, "currency" => currency} = row)
       when interval in ["month", "year"] do
    case row do
      %{"pricing" => "quote_required"} = quote when not is_map_key(quote, "amount") ->
        if Money.currency?(currency),
          do:
            {:ok,
             %{
               interval: String.to_existing_atom(interval),
               currency: currency,
               pricing: :quote_required,
               amount_minor: nil
             }},
          else: {:error, :invalid_currency}

      %{"amount" => amount} ->
        with {:ok, minor} <- Money.parse(amount, currency) do
          {:ok,
           %{
             interval: String.to_existing_atom(interval),
             currency: currency,
             pricing: :fixed,
             amount_minor: minor
           }}
        end

      _ ->
        {:error, :missing_amount}
    end
  end

  defp price(_), do: {:error, :invalid_price}

  defp unique_prices({:ok, prices}) do
    if prices |> Enum.map(&{&1.interval, &1.currency}) |> Enum.uniq() |> length() ==
         length(prices),
       do: {:ok, prices},
       else:
         {:error, field_error(:prices, "one price per interval and currency", :already_exists)}
  end

  defp unique_prices(error), do: error

  defp entitlements(attrs) do
    attrs
    |> Map.get("entitlements", [])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      row = stringify(row)
      key = row["feature_key"]
      limit = row["quantity_limit"]

      cond do
        not Features.known?(key) ->
          {:halt,
           {:error,
            field_error(:entitlements, "unknown feature #{inspect(key)}", :invalid_choice)}}

        not (is_nil(limit) or (is_integer(limit) and limit > 0)) ->
          {:halt,
           {:error, field_error(:entitlements, "quantity_limit must be positive", :out_of_range)}}

        Enum.any?(acc, &(&1.feature_key == key)) ->
          {:halt, {:error, field_error(:entitlements, "duplicate feature", :already_exists)}}

        true ->
          {:cont, {:ok, acc ++ [%{feature_key: key, quantity_limit: limit}]}}
      end
    end)
  end

  defp write_prices!(version, prices, entitlements) do
    for price <- prices,
        do:
          Repo.insert!(
            struct!(PriceVersion, Map.put(price, :plan_version_id, version.id)),
            @unlogged
          )

    for entitlement <- entitlements,
        do:
          Repo.insert!(
            struct!(PlanEntitlement, Map.put(entitlement, :plan_version_id, version.id)),
            @unlogged
          )

    :ok
  end

  defp lock_version(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %PlanVersion{} = version <-
           Repo.one(from(v in PlanVersion, where: v.id == ^id, lock: "FOR UPDATE"), @unlogged) do
      {:ok, version}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_plan(plan_id) do
    Repo.one!(
      from(p in Plan, where: p.id == ^plan_id, lock: "FOR UPDATE", select: p.id),
      @unlogged
    )

    :ok
  end

  defp status(%PlanVersion{status: status}, allowed) do
    if status in allowed,
      do: :ok,
      else: {:error, {:conflict, %{saas_plan_version: Atom.to_string(status)}}}
  end

  defp approval(reference) when is_binary(reference) do
    if String.trim(reference) == "",
      do: {:error, {:conflict, %{saas_plan_version: "approval_required"}}},
      else: :ok
  end

  defp approval(_), do: {:error, {:conflict, %{saas_plan_version: "approval_required"}}}

  defp provisional(%PlanVersion{price_source: :provisional}, opts) do
    if Keyword.get(opts, :confirm_provisional) == true,
      do: :ok,
      else: {:error, {:conflict, %{saas_plan_version: "provisional_confirmation_required"}}}
  end

  defp provisional(%PlanVersion{}, _opts), do: :ok

  defp priced(version) do
    if Repo.exists?(from(p in PriceVersion, where: p.plan_version_id == ^version.id)),
      do: :ok,
      else: {:error, {:conflict, %{saas_plan_version: "no_prices"}}}
  end

  defp supersede!(plan_id, now) do
    Repo.update_all(
      from(v in PlanVersion, where: v.plan_id == ^plan_id and v.status == :published),
      [set: [status: :superseded, superseded_at: now, updated_at: now]],
      @unlogged
    )
  end

  defp reload(version),
    do:
      Repo.preload(
        Repo.reload!(version, @unlogged),
        [:plan, prices: prices_order(), entitlements: entitlements_order()],
        force: true
      )

  defp prices_order, do: from(p in PriceVersion, order_by: [asc: p.currency, asc: p.interval])
  defp entitlements_order, do: from(e in PlanEntitlement, order_by: [asc: e.feature_key])

  defp audit!(event_type, actor, version, now, extra) do
    %AuditEvent{}
    |> struct!(
      Map.merge(
        %{
          event_type: event_type,
          actor: actor,
          plan_id: version.plan_id,
          plan_version_id: version.id,
          occurred_at: now
        },
        extra
      )
    )
    |> Repo.insert!(@unlogged)

    :telemetry.execute([:simple_fit, :billing, :catalog], %{count: 1}, %{event: event_type})
    :ok
  end

  defp field_error(field, message, validation),
    do:
      {%{}, %{field => :string}}
      |> Changeset.change()
      |> Changeset.add_error(field, message, validation: validation)

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(other), do: other
end
