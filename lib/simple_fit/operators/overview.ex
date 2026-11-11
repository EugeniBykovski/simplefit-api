defmodule SimpleFit.Operators.Overview do
  @moduledoc """
  The Control Plane overview (SF-121, AD1): platform counts, review queue sizes and
  health checks for an operator, as one read-only projection. The metric catalog,
  with each metric's source, inclusion rules and date semantics, is
  `docs/architecture/admin-overview-metrics.md`.

  * **Counts only.** Every number is a database aggregate computed by the context
    that owns it (`Accounts`, `Fighters`, `Coaches`, `Gyms`, `Sponsors`,
    `Operators`, `Observability`, `Billing`); no row, name or identifier leaves
    the database.
  * **Per-permission sections.** Platform counts need `platform.dashboard.read`
    (the operator count also `operators.read`), the sponsor review queue
    `sponsors.applications.read`, health `system.health.read`. A section the
    operator can't see is `restricted` with no value, never zero, and isn't
    queried at all. Gym verifications are `unavailable`: no operator permission
    or review exists for them yet.
  * **One snapshot.** All counts are read in one `REPEATABLE READ, READ ONLY`
    transaction, so they describe the same instant (`as_of`). Tests running in the
    SQL sandbox can't set the isolation level and turn it off (`snapshot: false`).
  * **Periods.** `24h`, `7d` (default) or `30d`, ending at `as_of` (now, rounded up to
    the second), start inclusive, end exclusive, in UTC. A period only drives the
    explicit "in period" counts; headline totals are always as of now.
  """

  alias SimpleFit.{Accounts, Billing, Coaches, Fighters, Gyms, Observability, Repo, Sponsors}

  @periods %{"24h" => 86_400, "7d" => 7 * 86_400, "30d" => 30 * 86_400}
  @default_period "7d"
  @day 86_400

  @type access :: :available | :restricted | :unavailable
  @type metric :: %{
          id: atom(),
          group: :population | :reviews,
          state: access(),
          value: non_neg_integer() | nil,
          breakdown: [{atom(), non_neg_integer()}],
          period_counts: [{atom(), non_neg_integer()}]
        }
  @type check :: %{
          id: atom(),
          status: :healthy | :degraded | :unknown | :no_telemetry | :unavailable,
          counts: [{atom(), non_neg_integer()}],
          last_event_at: DateTime.t() | nil
        }
  @type t :: %{
          as_of: DateTime.t(),
          period: %{key: String.t(), from: DateTime.t(), to: DateTime.t()},
          metrics: [metric()],
          health: %{state: :available | :restricted, checks: [check()]}
        }

  @doc "The supported periods, shortest first."
  @spec periods() :: [String.t()]
  def periods, do: ["24h", "7d", "30d"]

  @doc "The permissions that open at least one section of the overview."
  @spec permissions() :: [String.t()]
  def permissions, do: ~w(platform.dashboard.read sponsors.applications.read system.health.read)

  @doc "Validates the query: only `period`, one of `periods/0`; defaults to `7d`."
  @spec period(map()) :: {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def period(params) do
    {%{}, %{period: :string}}
    |> Ecto.Changeset.cast(params, [:period], empty_values: [])
    |> Ecto.Changeset.validate_inclusion(:period, periods())
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok, attrs} -> {:ok, Map.get(attrs, :period, @default_period)}
      error -> error
    end
  end

  @doc """
  Builds the overview for an operator holding `granted` permissions, for the period
  `key`, at `now`. Authorization is the caller's (`SimpleFit.Operators.overview/4`).
  """
  @spec build(MapSet.t(String.t()), String.t(), DateTime.t()) :: t()
  def build(%MapSet{} = granted, key, %DateTime{} = now \\ DateTime.utc_now()) do
    as_of = ceil_second(now)
    from = DateTime.add(as_of, -Map.fetch!(@periods, key), :second)

    {metrics, health} =
      snapshot(fn -> {metrics(granted, from, as_of), health(granted, as_of)} end)

    %{as_of: as_of, period: %{key: key, from: from, to: as_of}, metrics: metrics, health: health}
  end

  # The next whole second (or `now` itself when whole): every record stored before `as_of`
  # is counted, in the totals and in the period alike, and no column precision drops one.
  defp ceil_second(%DateTime{microsecond: {0, _}} = now), do: DateTime.truncate(now, :second)

  defp ceil_second(now),
    do: now |> DateTime.truncate(:second) |> DateTime.add(1, :second)

  @doc """
  Runs `fun` in one `REPEATABLE READ, READ ONLY` transaction, so the reads it makes
  describe the same instant: the overview's counts, and each SF-123 oversight detail
  (a gym's people and verification, a profile's counts). Off in the SQL sandbox
  (`snapshot: false`); the real-commit tests turn it on.
  """
  @spec snapshot((-> result)) :: result when result: term()
  def snapshot(fun) do
    if Keyword.get(Application.get_env(:simple_fit, __MODULE__, []), :snapshot, true) do
      {:ok, result} =
        Repo.transaction(fn ->
          %Postgrex.Result{} =
            Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [],
              log: false
            )

          fun.()
        end)

      result
    else
      fun.()
    end
  end

  ## Metrics

  defp metrics(granted, from, to) do
    platform? = MapSet.member?(granted, "platform.dashboard.read")
    operators? = platform? and MapSet.member?(granted, "operators.read")
    applications? = MapSet.member?(granted, "sponsors.applications.read")

    [
      population(:accounts, platform?, fn ->
        c = Accounts.registration_counts(from, to)

        {c.complete, [in_progress: c.in_progress, not_started: c.not_started],
         [registration_completed: c.completed_in_period]}
      end),
      population(:fighter_profiles, platform?, fn ->
        profile(Fighters.profile_counts(from, to))
      end),
      population(:coach_profiles, platform?, fn -> profile(Coaches.profile_counts(from, to)) end),
      population(:gyms, platform?, fn ->
        c = Gyms.setup_counts(from, to)
        {c.completed, [draft: c.draft], [setup_completed: c.completed_in_period]}
      end),
      population(:sponsor_organizations, platform?, fn ->
        c = Sponsors.organization_counts(from, to)
        {c.active, [suspended: c.suspended, closed: c.closed], [approved: c.approved_in_period]}
      end),
      population(:operators, operators?, fn -> {SimpleFit.Operators.active_count(), [], []} end),
      metric(:sponsor_applications_waiting, :reviews, applications?, fn ->
        c = Sponsors.application_counts(from, to)
        waiting = c.by_status.submitted + c.by_status.under_review

        {waiting, Enum.to_list(c.by_status),
         [
           first_submitted: c.first_submitted_in_period,
           approved: c.approved_in_period,
           rejected: c.rejected_in_period
         ]}
      end),
      %{
        id: :gym_verifications_waiting,
        group: :reviews,
        state: :unavailable,
        value: nil,
        breakdown: [],
        period_counts: []
      }
    ]
  end

  defp profile(c),
    do: {c.completed, [in_progress: c.in_progress], [onboarding_completed: c.completed_in_period]}

  defp population(id, granted?, fun), do: metric(id, :population, granted?, fun)

  defp metric(id, group, false, _fun),
    do: %{id: id, group: group, state: :restricted, value: nil, breakdown: [], period_counts: []}

  defp metric(id, group, true, fun) do
    {value, breakdown, period_counts} = fun.()

    %{
      id: id,
      group: group,
      state: :available,
      value: value,
      breakdown: breakdown,
      period_counts: period_counts
    }
  end

  ## Health

  defp health(granted, as_of) do
    if MapSet.member?(granted, "system.health.read") do
      jobs = Observability.job_counts(DateTime.add(as_of, -@day, :second))

      %{
        state: :available,
        checks: [
          # This projection's own queries just ran: the database answers.
          check(:database, :healthy),
          check(:background_jobs, if(jobs.discarded == 0, do: :healthy, else: :degraded),
            counts: [waiting: jobs.waiting, discarded_24h: jobs.discarded]
          ),
          # A receipt time isn't health: payments stay unknown.
          check(:payments_webhooks, :unknown, last_event_at: Billing.last_webhook_received_at()),
          check(:email_provider, :no_telemetry)
        ]
      }
    else
      %{state: :restricted, checks: []}
    end
  end

  defp check(id, status, opts \\ []) do
    %{
      id: id,
      status: status,
      counts: Keyword.get(opts, :counts, []),
      last_event_at: Keyword.get(opts, :last_event_at)
    }
  end
end
