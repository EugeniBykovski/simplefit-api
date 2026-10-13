defmodule SimpleFit.Entry do
  @moduledoc """
  Post-authentication entry resolution (ADR 0017, amended by SF-51): where an
  authenticated user should go next, as a semantic destination that web and
  mobile map to their own routes.

  Resolution is read-only and deterministic: every call derives the answer
  from canonical persisted state (shared account registration, ADR 0016;
  Fighter profile, ADR 0015; Coach profile, ADR 0020; the last explicitly
  chosen context) and the optional `intent` and `context` of the current
  navigation. Resolving writes nothing.

  Three inputs, three meanings (none of them grants anything):

    * `intent` - the journey the user explicitly asked to set up or enter
      (`fighter`, `coach`, `gym`, `sponsor`); it may lead into onboarding.
    * `context` - an application context the user asked to open (`fighter`,
      `coach`); honoured only when that context is completed, otherwise
      ignored. It never starts onboarding.
    * the last explicit context choice - recorded only by
      `record_context_choice/2` (a deliberate choice, never a sign-in or an
      intent), re-validated on every read.

  `capabilities` projects completed profiles (`FIGHTER`, `COACH`) for routing;
  authorization stays with each context. A completed Coach profile gives
  access to the user's own Coach application only.

  ## Decision rules (SF-49 §5.2, rows E1-E14), first match wins

    1. Account registration not complete -> `account_registration`
       (mandatory). Completion is monotonic.
    2. `intent: fighter` -> `fighter_home` when the Fighter profile is
       completed, otherwise `fighter_onboarding` (mandatory). `intent: coach`
       likewise -> `coach_home` / `coach_onboarding`, whatever the other
       profile's state. `gym` / `sponsor` -> `gym_onboarding` /
       `sponsor_application` (nothing is created).
    3. `context` naming a completed profile -> that profile's home.
    4. Otherwise, by completed profiles:
       * none: nothing started -> `role_selection`; one in progress -> its
         onboarding (mandatory); both in progress -> `context_selection`;
       * one -> its home (an unfinished other journey stays reachable with
         its intent);
       * both -> the last explicit choice's home, or `context_selection`.

  Profile contexts are not organizational workspaces: choosing a gym will be a
  separate step owned by the Gyms domain.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  require Logger

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaches
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Fighters
  alias SimpleFit.Repo

  @intents ~w(fighter coach gym sponsor)a
  @contexts ContextChoice.contexts()

  @type intent :: :fighter | :coach | :gym | :sponsor
  @type context :: :fighter | :coach
  @type destination ::
          :account_registration
          | :role_selection
          | :context_selection
          | :fighter_onboarding
          | :fighter_home
          | :coach_onboarding
          | :coach_home
          | :gym_onboarding
          | :sponsor_application
  @type reason ::
          :account_registration_incomplete
          | :fighter_onboarding_not_started
          | :fighter_onboarding_in_progress
          | :fighter_onboarding_completed
          | :coach_onboarding_not_started
          | :coach_onboarding_in_progress
          | :coach_onboarding_completed
          | :requested_context
          | :last_context
          | :context_choice_required
          | :multiple_roles_in_progress
          | :no_role_started
          | :coach_intent
          | :gym_intent
          | :sponsor_intent
  @type account_registration :: :not_started | :in_progress | :complete
  @type profile_status :: :not_started | :in_progress | :completed
  @type capability :: :fighter | :coach

  @typedoc """
  Loaded facts. `coach_profile`, `context` and `last_context` may be omitted
  (`:not_started`, `nil`, `nil`).
  """
  @type facts :: %{
          required(:intent) => intent() | nil,
          required(:account_registration) => account_registration(),
          required(:fighter_profile) => profile_status(),
          optional(:coach_profile) => profile_status(),
          optional(:context) => context() | nil,
          optional(:last_context) => context() | nil
        }

  @type t :: %{
          destination: destination(),
          reason: reason(),
          mandatory: boolean(),
          intent: intent() | nil,
          context: context() | nil,
          account_registration: account_registration(),
          fighter_profile: profile_status(),
          coach_profile: profile_status(),
          capabilities: [capability()]
        }

  @doc "The allowed navigation intents."
  @spec intents() :: [intent()]
  def intents, do: @intents

  @doc "The profile contexts a user can request or choose."
  @spec contexts() :: [context()]
  def contexts, do: @contexts

  @doc "Every destination `decide/1` can return."
  @spec destinations() :: [destination()]
  def destinations,
    do: [
      :account_registration,
      :role_selection,
      :context_selection,
      :fighter_onboarding,
      :fighter_home,
      :coach_onboarding,
      :coach_home,
      :gym_onboarding,
      :sponsor_application
    ]

  @doc """
  Every documented reason. `:coach_intent` is kept for contract compatibility
  (ADR 0003, additive only) but is no longer returned: a Coach intent now
  resolves by the Coach profile's state.
  """
  @spec reasons() :: [reason()]
  def reasons,
    do: [
      :account_registration_incomplete,
      :fighter_onboarding_not_started,
      :fighter_onboarding_in_progress,
      :fighter_onboarding_completed,
      :coach_onboarding_not_started,
      :coach_onboarding_in_progress,
      :coach_onboarding_completed,
      :requested_context,
      :last_context,
      :context_choice_required,
      :multiple_roles_in_progress,
      :no_role_started,
      :coach_intent,
      :gym_intent,
      :sponsor_intent
    ]

  @doc """
  Resolves the entry of an authenticated user. `params` may carry `"intent"`
  (one of `intents/0`) and `"context"` (one of `contexts/0`), as strings;
  absent, `nil` or `""` means none. Any other value is an `invalid_choice`
  validation error, never a role.
  """
  @spec resolve(User.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def resolve(%User{} = user, params \\ %{}) when is_map(params) do
    with {:ok, %{intent: intent, context: context}} <- cast_request(params) do
      entry =
        decide(%{
          intent: intent,
          context: context,
          account_registration: Accounts.get_account_registration(user).status,
          fighter_profile: user |> Fighters.get_profile() |> Fighters.onboarding_status(),
          coach_profile: user |> Coaches.get_profile() |> Coaches.onboarding_status(),
          last_context: last_context(user)
        })

      Logger.info("entry resolved",
        intent: entry.intent,
        entry_context: entry.context,
        destination: entry.destination,
        reason: entry.reason,
        account_registration: entry.account_registration,
        fighter_profile: entry.fighter_profile,
        coach_profile: entry.coach_profile
      )

      {:ok, entry}
    end
  end

  @doc "The pure decision rules (see the module doc) over already loaded facts."
  @spec decide(facts()) :: t()
  def decide(%{intent: intent, account_registration: account, fighter_profile: fighter} = facts) do
    profiles = %{fighter: fighter, coach: Map.get(facts, :coach_profile, :not_started)}
    completed = for context <- @contexts, profiles[context] == :completed, do: context
    requested = Map.get(facts, :context)
    applied = if requested in completed, do: requested

    {destination, reason} =
      route(account, intent, applied, profiles, completed, Map.get(facts, :last_context))

    %{
      destination: destination,
      reason: reason,
      mandatory: mandatory?(destination),
      intent: intent,
      context: if(account == :complete and is_nil(intent), do: applied),
      account_registration: account,
      fighter_profile: profiles.fighter,
      coach_profile: profiles.coach,
      capabilities: completed
    }
  end

  @doc """
  Records the user's explicit context choice (a context switcher or the
  context-selection screen). Only a completed profile context can be chosen;
  the latest choice replaces the previous one. Returns `{:error, :conflict}`
  when that context is not completed, and a changeset error for any value
  outside `contexts/0`.
  """
  @spec record_context_choice(User.t(), map()) ::
          {:ok, ContextChoice.t()} | {:error, :conflict | Ecto.Changeset.t()}
  def record_context_choice(%User{id: user_id} = user, params) when is_map(params) do
    with {:ok, context} <- cast_choice(params),
         :ok <- require_completed(user, context) do
      now = DateTime.utc_now()

      Repo.insert(
        %ContextChoice{user_id: user_id, context: context, chosen_at: now},
        on_conflict: [set: [context: context, chosen_at: now, updated_at: now]],
        conflict_target: :user_id,
        returning: true
      )
    end
  end

  ## Rules

  defp route(account, _intent, _context, _profiles, _completed, _last)
       when account != :complete,
       do: {:account_registration, :account_registration_incomplete}

  defp route(_account, intent, _context, profiles, _completed, _last)
       when intent in [:fighter, :coach],
       do: journey(intent, profiles[intent])

  defp route(_account, :gym, _context, _profiles, _completed, _last),
    do: {:gym_onboarding, :gym_intent}

  defp route(_account, :sponsor, _context, _profiles, _completed, _last),
    do: {:sponsor_application, :sponsor_intent}

  defp route(_account, nil, context, _profiles, _completed, _last) when not is_nil(context),
    do: {home(context), :requested_context}

  defp route(_account, nil, nil, profiles, [], _last) do
    case Enum.filter(@contexts, &(profiles[&1] == :in_progress)) do
      [] -> {:role_selection, :no_role_started}
      [context] -> journey(context, :in_progress)
      [_ | _] -> {:context_selection, :multiple_roles_in_progress}
    end
  end

  defp route(_account, nil, nil, _profiles, [context], _last), do: journey(context, :completed)

  defp route(_account, nil, nil, _profiles, completed, last) do
    if last in completed,
      do: {home(last), :last_context},
      else: {:context_selection, :context_choice_required}
  end

  defp journey(:fighter, :completed), do: {:fighter_home, :fighter_onboarding_completed}
  defp journey(:fighter, :in_progress), do: {:fighter_onboarding, :fighter_onboarding_in_progress}
  defp journey(:fighter, :not_started), do: {:fighter_onboarding, :fighter_onboarding_not_started}
  defp journey(:coach, :completed), do: {:coach_home, :coach_onboarding_completed}
  defp journey(:coach, :in_progress), do: {:coach_onboarding, :coach_onboarding_in_progress}
  defp journey(:coach, :not_started), do: {:coach_onboarding, :coach_onboarding_not_started}

  defp home(:fighter), do: :fighter_home
  defp home(:coach), do: :coach_home

  # Mandatory: the client goes here even when it holds a safe returnTo; the
  # returnTo is kept as a continuation and re-resolved afterwards. Onboarding
  # is mandatory whenever it is the destination: by an explicit intent, or as
  # the only journey a user without a completed profile has started.
  defp mandatory?(destination),
    do: destination in [:account_registration, :fighter_onboarding, :coach_onboarding]

  ## Inputs

  defp last_context(%User{id: user_id}) do
    Repo.one(from(c in ContextChoice, where: c.user_id == ^user_id, select: c.context))
  end

  defp require_completed(user, :fighter), do: completed?(Fighters.get_profile(user), Fighters)
  defp require_completed(user, :coach), do: completed?(Coaches.get_profile(user), Coaches)

  defp completed?(profile, context_module) do
    if context_module.onboarding_status(profile) == :completed, do: :ok, else: {:error, :conflict}
  end

  defp cast_request(params) do
    {%{}, %{intent: :string, context: :string}}
    |> cast(params, [:intent, :context], empty_values: [nil, ""])
    |> validate_inclusion(:intent, Enum.map(@intents, &Atom.to_string/1))
    |> validate_inclusion(:context, Enum.map(@contexts, &Atom.to_string/1))
    |> apply_action(:resolve)
    |> case do
      {:ok, values} ->
        {:ok, %{intent: to_atom(values[:intent]), context: to_atom(values[:context])}}

      {:error, _changeset} = error ->
        error
    end
  end

  defp cast_choice(params) do
    {%{}, %{context: :string}}
    |> cast(params, [:context], empty_values: [nil, ""])
    |> reject_unknown_keys(params, ["context", :context])
    |> validate_required([:context])
    |> validate_inclusion(:context, Enum.map(@contexts, &Atom.to_string/1))
    |> apply_action(:record)
    |> case do
      {:ok, %{context: context}} -> {:ok, String.to_existing_atom(context)}
      {:error, _changeset} = error -> error
    end
  end

  # Keys stay as given (never converted to atoms); only the key is reported.
  defp reject_unknown_keys(changeset, params, known) do
    params
    |> Map.keys()
    |> Enum.reject(&(&1 in known))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a field of the request", []}} | acc.errors], valid?: false}
    end)
  end

  defp to_atom(nil), do: nil
  defp to_atom(value), do: String.to_existing_atom(value)
end
