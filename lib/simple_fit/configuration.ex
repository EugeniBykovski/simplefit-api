defmodule SimpleFit.Configuration do
  @moduledoc """
  Configuration governance (SF-128, D-SA35): what the platform's feature switches are,
  where each one's value comes from, which code reads it, and the only change an
  operator can make at runtime.

  ## Sources

  Every switch is deployment configuration: an environment variable read once by
  `config/runtime.exs` into the application environment (or, for API docs, at
  compile time). Nothing here writes the environment. The registry lists each
  switch with its variable, consumer, risk and control; anything not listed (secrets,
  credentials, URLs, provider and operator settings) is never shown or changed here.

  ## The one runtime change: suspension

  For the allowlisted features (`suspendable/0`) the database holds a suspension
  (`runtime_flags`). It can only turn a feature **off**:

      effective = deployment enabled AND NOT suspended

  so no runtime change can enable a feature its deployment left off (release
  approvals, D-SA09, invitation page gates stay in force). Restoring removes the
  suspension; the deployment still decides. Payments, Stripe mode, coaching (legal
  consent) and API docs are read-only.

  ## Evaluation and propagation

  A consumer's check (`enabled?/1`) reads the committed row on every call, without a
  cache, so a committed change takes effect on the next check in every application
  instance sharing the database. If the row can't be read, the feature counts as
  suspended (fails closed). A suspension doesn't recall what already happened: sent
  emails and stored files stay.

  Changes run through the SF-111 framework (`SimpleFit.Operators.ConfigurationActions`).
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Billing.Stripe.Config, as: StripeConfig
  alias SimpleFit.Configuration.{FlagRevision, RuntimeFlag}
  alias SimpleFit.Repo

  @unlogged [log: false]
  @history_limit 50

  # Each switch: its variable, the deployment value's location in the application
  # environment, the function that consumes it, the control and the risk.
  @registry [
    %{
      key: "gym.member_invitations",
      group: :gyms,
      variable: "GYM_MEMBER_INVITATIONS",
      deployment: {SimpleFit.Gyms, :member_invitations},
      consumer: "SimpleFit.Gyms.MemberInvitations.delivery_enabled?/0",
      control: :suspendable,
      risk: :medium,
      decision: "SF-95",
      impact: ["new_member_invitation_emails_stop", "sent_invitations_unchanged"]
    },
    %{
      key: "gym.staff_invitations",
      group: :gyms,
      variable: "GYM_STAFF_INVITATIONS",
      deployment: {SimpleFit.Gyms, :staff_invitations},
      consumer: "SimpleFit.Gyms.StaffInvitations.delivery_enabled?/0",
      control: :suspendable,
      risk: :medium,
      decision: "SF-133",
      impact: ["new_staff_invitation_emails_stop", "sent_invitations_unchanged"]
    },
    %{
      key: "sponsor.application_emails",
      group: :sponsors,
      variable: "SPONSOR_APPLICATION_EMAILS",
      deployment: {SimpleFit.Sponsors, :application_emails},
      consumer: "SimpleFit.Sponsors.ApplicationNotifications.enabled?/0",
      control: :suspendable,
      risk: :medium,
      decision: "SF-114",
      impact: ["sponsor_application_emails_not_sent", "applications_unchanged"]
    },
    %{
      key: "sponsor.evidence_uploads",
      group: :sponsors,
      variable: "SPONSOR_EVIDENCE_UPLOADS",
      deployment: {SimpleFit.Sponsors, :evidence_uploads},
      consumer: "SimpleFit.Sponsors.Evidence.enabled?/0",
      control: :suspendable,
      risk: :medium,
      decision: "D-SA09",
      impact: ["new_evidence_uploads_refused", "stored_files_unchanged"]
    },
    %{
      key: "coaching.access",
      group: :coaching,
      variable: "COACHING_ACCESS_ENABLED",
      deployment: {SimpleFit.Coaching, :access_enabled},
      consumer: "SimpleFit.Coaching.access_enabled?/0",
      control: :read_only,
      risk: :high,
      decision: "ADR 0021",
      impact: []
    },
    %{
      key: "stripe.billing",
      group: :payments,
      variable: "STRIPE_BILLING_ENABLED",
      deployment: {SimpleFit.Billing.Stripe, :enabled},
      consumer: "SimpleFit.Billing.Stripe.Config.status/0",
      control: :read_only,
      risk: :high,
      decision: "SF-138",
      impact: []
    },
    %{
      key: "stripe.mode",
      group: :payments,
      variable: "STRIPE_MODE",
      deployment: {SimpleFit.Billing.Stripe, :mode},
      consumer: "SimpleFit.Billing.Stripe.Config.status/0",
      control: :read_only,
      risk: :high,
      decision: "SF-138",
      impact: []
    },
    %{
      key: "stripe.connect",
      group: :payments,
      variable: "STRIPE_CONNECT_ENABLED",
      deployment: {SimpleFit.Billing.Stripe, :connect_enabled},
      consumer: "SimpleFit.Billing.Stripe.Config.status/0",
      control: :read_only,
      risk: :high,
      decision: "SF-102",
      impact: []
    },
    %{
      key: "api.docs",
      group: :platform,
      variable: "API_DOCS_ENABLED",
      deployment: {:api_docs, :enabled},
      consumer: "SimpleFitWeb.Router (compiled)",
      control: :build,
      risk: :medium,
      decision: "CLAUDE.md §15",
      impact: []
    }
  ]

  @suspendable for entry <- @registry, entry.control == :suspendable, do: entry.key

  @typedoc "A registered switch with its current values."
  @type entry :: map()

  @doc "The keys an operator can suspend and restore."
  @spec suspendable() :: [String.t()]
  def suspendable, do: @suspendable

  @doc "Every registered key."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@registry, & &1.key)

  @doc "The deployment environment this API runs in (`SENTRY_ENVIRONMENT`, else the Mix env)."
  @spec environment() :: String.t()
  def environment,
    do: Application.get_env(:simple_fit, :observability, [])[:environment] || "unknown"

  @doc """
  Whether the suspendable feature `key` is on right now: its deployment enabled it and
  no operator suspended it. Reads the committed suspension on every call; an unreadable
  suspension counts as suspended.
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(key) when key in @suspendable do
    entry = entry!(key)
    deployment_value(entry) == true and not suspended?(key)
  end

  defp suspended?(key) do
    case Repo.one(from(f in RuntimeFlag, where: f.key == ^key, select: f.suspended), @unlogged) do
      nil -> false
      suspended -> suspended
    end
  rescue
    DBConnection.ConnectionError -> true
  end

  @doc "Every registered switch with its deployment value, suspension and effective value."
  @spec inventory() :: [entry()]
  def inventory do
    flags = Map.new(Repo.all(RuntimeFlag, @unlogged), &{&1.key, &1})
    Enum.map(@registry, &view(&1, Map.get(flags, &1.key)))
  end

  @doc "One runtime flag by id, with its newest #{@history_limit} changes, or `nil`."
  @spec flag(Ecto.UUID.t()) :: entry() | nil
  def flag(id) do
    case Repo.get(RuntimeFlag, id, @unlogged) do
      nil ->
        nil

      %RuntimeFlag{} = flag ->
        flag.key
        |> entry!()
        |> view(flag)
        |> Map.put(:history, history(flag.id))
    end
  end

  @doc "The newest changes across every runtime flag."
  @spec recent_changes() :: [map()]
  def recent_changes do
    from(r in FlagRevision,
      join: f in RuntimeFlag,
      on: f.id == r.flag_id,
      order_by: [desc: r.inserted_at, desc: r.revision],
      limit: @history_limit,
      select: {f.key, r}
    )
    |> Repo.all(@unlogged)
    |> Enum.map(fn {key, revision} -> revision |> revision_view() |> Map.put(:key, key) end)
  end

  defp history(flag_id) do
    from(r in FlagRevision,
      where: r.flag_id == ^flag_id,
      order_by: [desc: r.revision],
      limit: @history_limit
    )
    |> Repo.all(@unlogged)
    |> Enum.map(&revision_view/1)
  end

  defp revision_view(%FlagRevision{} = r) do
    %{
      revision: r.revision,
      change: r.change,
      suspended: r.suspended,
      previous_suspended: r.previous_suspended,
      operator_id: r.operator_id,
      reason_code: r.reason_code,
      changed_at: r.inserted_at
    }
  end

  defp view(entry, flag) do
    deployment = deployment_value(entry)
    suspended = flag != nil and flag.suspended

    %{
      key: entry.key,
      group: entry.group,
      variable: entry.variable,
      consumer: entry.consumer,
      control: entry.control,
      risk: entry.risk,
      decision: entry.decision,
      impact: entry.impact,
      deployment_value: deployment,
      suspended: suspended,
      effective: effective(entry, deployment, suspended),
      flag_id: flag && flag.id,
      revision: flag && flag.revision,
      updated_at: flag && flag.updated_at
    }
  end

  defp effective(%{control: :suspendable}, deployment, suspended),
    do: deployment == true and not suspended

  defp effective(%{key: "stripe.billing"}, _deployment, _suspended),
    do: StripeConfig.status() |> stripe_state()

  defp effective(_entry, deployment, _suspended), do: deployment

  defp stripe_state(:disabled), do: false
  defp stripe_state({:misconfigured, _}), do: false
  defp stripe_state({:ready, _}), do: true

  # The value the deployment configured. Only booleans and Stripe's mode are
  # registered: nothing secret is ever read here.
  defp deployment_value(%{deployment: {app_key, field}}) do
    case Application.get_env(:simple_fit, app_key, [])[field] do
      value when is_boolean(value) -> value
      value when value in [:test, :live] -> Atom.to_string(value)
      nil -> false
      _other -> false
    end
  end

  defp entry!(key), do: Enum.find(@registry, &(&1.key == key)) || raise(ArgumentError)

  ## Runtime flag changes (only through SimpleFit.Operators.ConfigurationActions)

  @doc false
  @spec fetch_flag(Ecto.UUID.t()) :: RuntimeFlag.t() | nil
  def fetch_flag(id), do: Repo.get(RuntimeFlag, id, @unlogged)

  @doc false
  @spec lock_flag!(Ecto.UUID.t()) :: RuntimeFlag.t() | nil
  def lock_flag!(id) do
    true = Repo.in_transaction?()
    Repo.one(from(f in RuntimeFlag, where: f.id == ^id, lock: "FOR UPDATE"), @unlogged)
  end

  @doc false
  @spec flag_entry(RuntimeFlag.t()) :: entry()
  def flag_entry(%RuntimeFlag{} = flag), do: flag.key |> entry!() |> view(flag)

  @doc """
  Inside the action's transaction, with the flag locked: sets `suspended`, which
  raises the revision, and appends the change to the history. Called only by the
  SF-111 action.
  """
  @spec set_suspended!(RuntimeFlag.t(), boolean(), Ecto.UUID.t(), String.t(), Ecto.UUID.t()) ::
          RuntimeFlag.t()
  def set_suspended!(%RuntimeFlag{suspended: from} = flag, to, operator_id, reason, operation_id)
      when is_boolean(to) and from != to do
    true = Repo.in_transaction?()

    updated =
      flag
      |> Ecto.Changeset.change(suspended: to)
      |> Repo.update!(@unlogged)

    Repo.insert!(
      %FlagRevision{
        flag_id: flag.id,
        revision: updated.revision,
        change: if(to, do: :suspend, else: :restore),
        suspended: to,
        previous_suspended: from,
        operator_id: operator_id,
        reason_code: reason,
        operation_id: operation_id
      },
      @unlogged
    )

    updated
  end
end
