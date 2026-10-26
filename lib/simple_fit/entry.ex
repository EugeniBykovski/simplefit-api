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

  ## Decision rules (SF-49 §5.2, rows E1-E14; SF-84 gyms), first match wins

    1. Account registration not complete -> `account_registration`
       (mandatory). Completion is monotonic.
    2. `intent: fighter` -> `fighter_home` when the Fighter profile is
       completed, otherwise `fighter_onboarding` (mandatory). `intent: coach`
       likewise -> `coach_home` / `coach_onboarding`, whatever the other
       profile's state.
    3. `intent: gym` (SF-84) -> by the user's real gym workspaces: none ->
       `gym_onboarding` (setup not started; nothing is created); only the
       draft they own -> `gym_onboarding` resuming it (`gym_id`); exactly one
       completed gym and no draft -> `gym_home` (`gym_id`); several (or a
       completed gym and a draft) -> the remembered gym when it is still
       valid and there is no draft, otherwise `gym_selection`.
       `sponsor` -> `sponsor_application` (nothing is created).
    4. `context` naming a completed profile, or `context: gym` with a
       `gym_id` of a completed gym where the user is active staff -> that
       home (`requested_context`). Anything else is ignored.
    5. Otherwise, by completed contexts (completed profiles and completed
       gym workspaces, each gym counting once):
       * none: nothing started -> `role_selection`; one journey in progress
         (a profile onboarding, or the gym draft the user owns) -> resume it;
         several -> `context_selection`;
       * one -> its home (an unfinished other journey stays reachable with
         its intent);
       * several -> the last explicit choice's home while still valid, or
         `context_selection`.

  `capabilities` projects completed profiles (`FIGHTER`, `COACH`) and, from
  an active staff membership at a gym with a completed setup,
  `GYM_WORKSPACE`. A draft gym grants no capability: its owner resumes setup
  through rule 3 or 5. Gym facts come only from `SimpleFit.Gyms` (the
  viewer's own active memberships, re-read on every resolution), and a gym
  id in the answer is navigation: every gym operation authorizes the id in
  its own path (ADR 0026, D-G15/D-G23).
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  require Logger

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaches
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Fighters
  alias SimpleFit.Gyms
  alias SimpleFit.Repo

  @intents ~w(fighter coach gym sponsor)a
  @contexts ContextChoice.contexts()
  @profile_contexts [:fighter, :coach]

  # Gym workspace summaries carried in one answer; the full, paginated list
  # is `listMyGyms` (SF-83).
  @chooser_limit 25

  @no_gyms %{completed_count: 0, single_completed_gym_id: nil, open_draft_gym_id: nil}

  @type intent :: :fighter | :coach | :gym | :sponsor
  @type context :: :fighter | :coach | :gym
  @type destination ::
          :account_registration
          | :role_selection
          | :context_selection
          | :fighter_onboarding
          | :fighter_home
          | :coach_onboarding
          | :coach_home
          | :gym_onboarding
          | :gym_home
          | :gym_selection
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
          | :gym_setup_not_started
          | :gym_setup_in_progress
          | :gym_workspace_completed
          | :gym_choice_required
  @type account_registration :: :not_started | :in_progress | :complete
  @type profile_status :: :not_started | :in_progress | :completed
  @type capability :: :fighter | :coach | :gym_workspace

  @typedoc "The viewer's gym workspace counts (see `SimpleFit.Gyms.workspace_overview/2`)."
  @type gym_facts :: %{
          completed_count: non_neg_integer(),
          single_completed_gym_id: Ecto.UUID.t() | nil,
          open_draft_gym_id: Ecto.UUID.t() | nil
        }

  @typedoc """
  Loaded facts. Everything but `intent`, `account_registration` and
  `fighter_profile` may be omitted (`:not_started`, `nil`, no gyms).
  `requested_gym` is the `context: gym` target when the user is active staff
  there; `last_gym_id` is the remembered gym only while it is still a
  completed gym where the user is active staff.
  """
  @type facts :: %{
          required(:intent) => intent() | nil,
          required(:account_registration) => account_registration(),
          required(:fighter_profile) => profile_status(),
          optional(:coach_profile) => profile_status(),
          optional(:context) => context() | nil,
          optional(:last_context) => context() | nil,
          optional(:gyms) => gym_facts(),
          optional(:requested_gym) => Gyms.workspace_summary() | nil,
          optional(:last_gym_id) => Ecto.UUID.t() | nil,
          optional(:gym_workspaces) => [map()],
          optional(:gym_workspace_count) => non_neg_integer()
        }

  @type t :: %{
          destination: destination(),
          reason: reason(),
          mandatory: boolean(),
          intent: intent() | nil,
          context: context() | nil,
          gym_id: Ecto.UUID.t() | nil,
          account_registration: account_registration(),
          fighter_profile: profile_status(),
          coach_profile: profile_status(),
          capabilities: [capability()],
          gym_workspaces: [map()],
          gym_workspace_count: non_neg_integer()
        }

  @doc "The allowed navigation intents."
  @spec intents() :: [intent()]
  def intents, do: @intents

  @doc "The contexts a user can request or choose (profiles, and `gym` with a gym id)."
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
      :gym_home,
      :gym_selection,
      :sponsor_application
    ]

  @doc """
  Every documented reason. `:coach_intent` is kept for contract compatibility
  (ADR 0003, additive only) but is no longer returned: a Coach intent now
  resolves by the Coach profile's state. `:gym_intent` likewise (SF-84): a
  Gym intent resolves by the user's gym workspaces.
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
      :sponsor_intent,
      :gym_setup_not_started,
      :gym_setup_in_progress,
      :gym_workspace_completed,
      :gym_choice_required
    ]

  @doc """
  Resolves the entry of an authenticated user. `params` may carry `"intent"`
  (one of `intents/0`), `"context"` (one of `contexts/0`) and, with
  `context: gym`, `"gym_id"`, as strings; absent, `nil` or `""` means none.
  Any other value is a validation error, never a role. Read-only.
  """
  @spec resolve(User.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def resolve(%User{} = user, params \\ %{}) when is_map(params) do
    with {:ok, %{intent: intent, context: context, gym_id: gym_id}} <- cast_request(params) do
      overview = Gyms.workspace_overview(user, @chooser_limit)
      choice = last_choice(user)
      last_gym_id = valid_last_gym(user, choice)

      entry =
        decide(%{
          intent: intent,
          context: context,
          account_registration: Accounts.get_account_registration(user).status,
          fighter_profile: user |> Fighters.get_profile() |> Fighters.onboarding_status(),
          coach_profile: user |> Coaches.get_profile() |> Coaches.onboarding_status(),
          last_context: choice && choice.context,
          gyms: Map.take(overview, Map.keys(@no_gyms)),
          requested_gym: requested_gym(user, context, gym_id),
          last_gym_id: last_gym_id,
          gym_workspaces:
            Enum.map(overview.entries, &Map.put(&1, :selected, &1.gym_id == last_gym_id)),
          gym_workspace_count: overview.total
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
    gyms = Map.merge(@no_gyms, Map.get(facts, :gyms, %{}))
    completed = for context <- @profile_contexts, profiles[context] == :completed, do: context
    requested_gym = Map.get(facts, :requested_gym)
    applied = applied_context(Map.get(facts, :context), completed, requested_gym)

    state = %{
      profiles: profiles,
      completed: completed,
      gyms: gyms,
      requested_gym: requested_gym,
      last: Map.get(facts, :last_context),
      last_gym_id: Map.get(facts, :last_gym_id)
    }

    {destination, reason, gym_id} = route(account, intent, applied, state)

    %{
      destination: destination,
      reason: reason,
      mandatory: mandatory?(destination),
      intent: intent,
      context: if(account == :complete and is_nil(intent), do: applied),
      gym_id: gym_id,
      account_registration: account,
      fighter_profile: profiles.fighter,
      coach_profile: profiles.coach,
      capabilities: completed ++ if(gyms.completed_count > 0, do: [:gym_workspace], else: []),
      gym_workspaces: Map.get(facts, :gym_workspaces, []),
      gym_workspace_count: Map.get(facts, :gym_workspace_count, 0)
    }
  end

  @doc """
  Records the user's explicit context choice (a context switcher or the
  context-selection screen): a completed profile (`fighter`, `coach`) or,
  with `gym_id`, a gym with a completed setup where the user holds an active
  staff membership (SF-84). The latest choice replaces the previous one.
  `{:error, :conflict}` when the profile is not completed, `{:conflict,
  %{setup_status: "draft"}}` for a draft gym, `{:error, :not_found}` for any
  gym where the user is not active staff (existence is never revealed), and
  a changeset error for anything else. The gym membership is share-locked
  while the choice is written, so a concurrent revocation commits either
  before (`not_found`) or after it (the choice is then ignored on every
  read).
  """
  @spec record_context_choice(User.t(), map()) ::
          {:ok, ContextChoice.t()}
          | {:error, :conflict | :not_found | {:conflict, map()} | Ecto.Changeset.t()}
  def record_context_choice(%User{} = user, params) when is_map(params) do
    with {:ok, choice} <- cast_choice(params) do
      store_choice(user, choice)
    end
  end

  defp store_choice(user, %{context: :gym, gym_id: gym_id}) do
    Repo.transaction(fn ->
      case Gyms.lock_workspace(user, gym_id) do
        {:ok, %{setup_status: :completed, gym_id: id}} -> upsert_choice!(user, :gym, id)
        {:ok, %{setup_status: :draft}} -> Repo.rollback({:conflict, %{setup_status: "draft"}})
        {:error, :not_found} -> Repo.rollback(:not_found)
      end
    end)
  end

  defp store_choice(user, %{context: context}) do
    with :ok <- require_completed(user, context), do: {:ok, upsert_choice!(user, context, nil)}
  end

  defp upsert_choice!(%User{id: user_id}, context, gym_id) do
    now = DateTime.utc_now()

    Repo.insert!(
      %ContextChoice{user_id: user_id, context: context, gym_id: gym_id, chosen_at: now},
      on_conflict: [set: [context: context, gym_id: gym_id, chosen_at: now, updated_at: now]],
      conflict_target: :user_id,
      returning: true
    )
  end

  ## Rules

  defp applied_context(requested, completed, _requested_gym)
       when requested in [:fighter, :coach] do
    if requested in completed, do: requested
  end

  defp applied_context(:gym, _completed, %{setup_status: :completed}), do: :gym
  defp applied_context(_requested, _completed, _requested_gym), do: nil

  defp route(account, _intent, _context, _state) when account != :complete,
    do: {:account_registration, :account_registration_incomplete, nil}

  defp route(_account, intent, _context, state) when intent in [:fighter, :coach],
    do: with_no_gym(journey(intent, state.profiles[intent]))

  defp route(_account, :gym, _context, state), do: gym_intent(state)

  defp route(_account, :sponsor, _context, _state),
    do: {:sponsor_application, :sponsor_intent, nil}

  defp route(_account, nil, :gym, state),
    do: {:gym_home, :requested_context, state.requested_gym.gym_id}

  defp route(_account, nil, context, _state) when not is_nil(context),
    do: {home(context), :requested_context, nil}

  defp route(_account, nil, nil, state) do
    case length(state.completed) + state.gyms.completed_count do
      0 -> resume(state)
      1 -> only_completed(state)
      _several -> last_or_choose(state)
    end
  end

  # A Gym intent never creates anything: it resolves by real workspaces.
  defp gym_intent(%{gyms: %{completed_count: 0, open_draft_gym_id: nil}}),
    do: {:gym_onboarding, :gym_setup_not_started, nil}

  defp gym_intent(%{gyms: %{completed_count: 0, open_draft_gym_id: draft}}),
    do: {:gym_onboarding, :gym_setup_in_progress, draft}

  defp gym_intent(%{gyms: %{completed_count: 1, open_draft_gym_id: nil} = gyms}),
    do: {:gym_home, :gym_workspace_completed, gyms.single_completed_gym_id}

  defp gym_intent(%{gyms: %{open_draft_gym_id: nil}, last_gym_id: last}) when is_binary(last),
    do: {:gym_home, :last_context, last}

  defp gym_intent(_state), do: {:gym_selection, :gym_choice_required, nil}

  # No completed context: resume the one journey in progress, if any.
  defp resume(state) do
    profile_journeys = Enum.filter(@profile_contexts, &(state.profiles[&1] == :in_progress))
    draft = state.gyms.open_draft_gym_id
    journeys = profile_journeys ++ if(draft, do: [:gym], else: [])

    case journeys do
      [] -> {:role_selection, :no_role_started, nil}
      [:gym] -> {:gym_onboarding, :gym_setup_in_progress, draft}
      [context] -> with_no_gym(journey(context, :in_progress))
      [_ | _] -> {:context_selection, :multiple_roles_in_progress, nil}
    end
  end

  defp only_completed(%{completed: [context]}), do: with_no_gym(journey(context, :completed))

  defp only_completed(%{gyms: gyms}),
    do: {:gym_home, :gym_workspace_completed, gyms.single_completed_gym_id}

  defp last_or_choose(%{last: :gym, last_gym_id: gym_id}) when is_binary(gym_id),
    do: {:gym_home, :last_context, gym_id}

  defp last_or_choose(%{last: last, completed: completed}) do
    if last in completed,
      do: {home(last), :last_context, nil},
      else: {:context_selection, :context_choice_required, nil}
  end

  defp with_no_gym({destination, reason}), do: {destination, reason, nil}

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

  defp last_choice(%User{id: user_id}) do
    Repo.one(
      from(c in ContextChoice,
        where: c.user_id == ^user_id,
        select: %{context: c.context, gym_id: c.gym_id}
      )
    )
  end

  # A remembered gym counts only while it is a completed gym where the user
  # is still active staff; otherwise it is ignored (never deleted by a read).
  defp valid_last_gym(user, %{context: :gym, gym_id: gym_id}) do
    case Gyms.workspace(user, gym_id) do
      {:ok, %{setup_status: :completed, gym_id: id}} -> id
      _unavailable -> nil
    end
  end

  defp valid_last_gym(_user, _choice), do: nil

  defp requested_gym(user, :gym, gym_id) do
    case Gyms.workspace(user, gym_id) do
      {:ok, workspace} -> workspace
      {:error, :not_found} -> nil
    end
  end

  defp requested_gym(_user, _context, _gym_id), do: nil

  defp require_completed(user, :fighter), do: completed?(Fighters.get_profile(user), Fighters)
  defp require_completed(user, :coach), do: completed?(Coaches.get_profile(user), Coaches)

  defp completed?(profile, context_module) do
    if context_module.onboarding_status(profile) == :completed, do: :ok, else: {:error, :conflict}
  end

  defp cast_request(params) do
    {%{}, %{intent: :string, context: :string, gym_id: Ecto.UUID}}
    |> cast(params, [:intent, :context, :gym_id], empty_values: [nil, ""])
    |> validate_inclusion(:intent, Enum.map(@intents, &Atom.to_string/1))
    |> validate_inclusion(:context, Enum.map(@contexts, &Atom.to_string/1))
    |> validate_gym_id()
    |> apply_action(:resolve)
    |> case do
      {:ok, values} ->
        {:ok,
         %{
           intent: to_atom(values[:intent]),
           context: to_atom(values[:context]),
           gym_id: values[:gym_id]
         }}

      {:error, _changeset} = error ->
        error
    end
  end

  defp cast_choice(params) do
    {%{}, %{context: :string, gym_id: Ecto.UUID}}
    |> cast(params, [:context, :gym_id], empty_values: [nil, ""])
    |> reject_unknown_keys(params, ["context", :context, "gym_id", :gym_id])
    |> validate_required([:context])
    |> validate_inclusion(:context, Enum.map(@contexts, &Atom.to_string/1))
    |> validate_gym_id()
    |> apply_action(:record)
    |> case do
      {:ok, %{context: context} = values} ->
        {:ok, %{context: String.to_existing_atom(context), gym_id: values[:gym_id]}}

      {:error, _changeset} = error ->
        error
    end
  end

  # `gym_id` goes with `context: gym`, and only with it. A malformed id is
  # already a cast error and is reported once.
  defp validate_gym_id(changeset) do
    if Keyword.has_key?(changeset.errors, :gym_id),
      do: changeset,
      else: validate_gym_id_pairing(changeset)
  end

  defp validate_gym_id_pairing(changeset) do
    case {get_field(changeset, :context), get_field(changeset, :gym_id)} do
      {"gym", nil} -> add_error(changeset, :gym_id, "can't be blank", validation: :required)
      {"gym", _gym_id} -> changeset
      {_other, nil} -> changeset
      {_other, _gym_id} -> add_error(changeset, :gym_id, "is only allowed with context gym")
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
