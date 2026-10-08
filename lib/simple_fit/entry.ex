defmodule SimpleFit.Entry do
  @moduledoc """
  Post-authentication entry resolution (ADR 0017): where an authenticated
  user should go next, as a semantic destination that web and mobile map to
  their own routes.

  Read-only and deterministic: every call derives the answer from canonical
  persisted state (shared account registration, ADR 0016; Fighter profile,
  ADR 0015) and the optional explicit `intent` of the current navigation.
  Nothing is written: the intent is never stored, and no "current
  destination" exists to drift between tabs or devices.

  The intent answers "which journey did the user explicitly try to enter?",
  never "what may this user do?". It grants nothing; `capabilities` only
  projects real backend state for routing, and authorization stays with
  each context.

  ## Decision rules, in order

    1. Account registration not complete -> `account_registration`
       (mandatory). Completion is monotonic, so a later Terms or Privacy
       version change never reopens it.
    2. `intent: fighter` -> `fighter_onboarding` until the Fighter profile is
       complete, then `fighter_home`.
    3. `intent: coach` / `gym` / `sponsor` -> `coach_onboarding` /
       `gym_onboarding` / `sponsor_application`. No Coach profile, Gym or
       Sponsor workspace is created or implied.
    4. No intent: the Fighter profile is the only role state that exists, so
       an in-progress one resumes (`fighter_onboarding`), a completed one
       goes home (`fighter_home`), and otherwise the user chooses
       (`role_selection`). No role is ever assumed.
  """

  import Ecto.Changeset

  require Logger

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Fighters

  @intents ~w(fighter coach gym sponsor)a

  @type intent :: :fighter | :coach | :gym | :sponsor
  @type destination ::
          :account_registration
          | :role_selection
          | :fighter_onboarding
          | :fighter_home
          | :coach_onboarding
          | :gym_onboarding
          | :sponsor_application
  @type reason ::
          :account_registration_incomplete
          | :fighter_onboarding_not_started
          | :fighter_onboarding_in_progress
          | :fighter_onboarding_completed
          | :no_role_started
          | :coach_intent
          | :gym_intent
          | :sponsor_intent
  @type account_registration :: :not_started | :in_progress | :complete
  @type fighter_profile :: :not_started | :in_progress | :completed
  @type capability :: :fighter

  @type facts :: %{
          intent: intent() | nil,
          account_registration: account_registration(),
          fighter_profile: fighter_profile()
        }

  @type t :: %{
          destination: destination(),
          reason: reason(),
          mandatory: boolean(),
          intent: intent() | nil,
          account_registration: account_registration(),
          fighter_profile: fighter_profile(),
          capabilities: [capability()]
        }

  @doc "The allowed navigation intents."
  @spec intents() :: [intent()]
  def intents, do: @intents

  @doc "Every destination `decide/1` can return."
  @spec destinations() :: [destination()]
  def destinations,
    do: [
      :account_registration,
      :role_selection,
      :fighter_onboarding,
      :fighter_home,
      :coach_onboarding,
      :gym_onboarding,
      :sponsor_application
    ]

  @doc "Every reason `decide/1` can return."
  @spec reasons() :: [reason()]
  def reasons,
    do: [
      :account_registration_incomplete,
      :fighter_onboarding_not_started,
      :fighter_onboarding_in_progress,
      :fighter_onboarding_completed,
      :no_role_started,
      :coach_intent,
      :gym_intent,
      :sponsor_intent
    ]

  @doc """
  Resolves the entry of an authenticated user. `params` may carry `"intent"`
  (one of `intents/0`, as a string); absent, `nil` or `""` means no intent.
  Any other value is an `invalid_choice` validation error, never a role.
  """
  @spec resolve(User.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def resolve(%User{} = user, params \\ %{}) when is_map(params) do
    with {:ok, intent} <- cast_intent(params) do
      registration = Accounts.get_account_registration(user)
      fighter = user |> Fighters.get_profile() |> Fighters.onboarding_status()

      entry =
        decide(%{
          intent: intent,
          account_registration: registration.status,
          fighter_profile: fighter
        })

      Logger.info("entry resolved",
        intent: entry.intent,
        destination: entry.destination,
        reason: entry.reason,
        account_registration: entry.account_registration,
        fighter_profile: entry.fighter_profile
      )

      {:ok, entry}
    end
  end

  @doc "The pure decision rules (see the module doc) over already loaded facts."
  @spec decide(facts()) :: t()
  def decide(%{intent: intent, account_registration: account, fighter_profile: fighter} = facts) do
    {destination, reason} = route(intent, account, fighter)

    Map.merge(facts, %{
      destination: destination,
      reason: reason,
      mandatory: mandatory?(destination),
      capabilities: capabilities(fighter)
    })
  end

  defp route(_intent, account, _fighter) when account != :complete,
    do: {:account_registration, :account_registration_incomplete}

  defp route(intent, _account, fighter) when intent in [:fighter, nil],
    do: fighter_route(intent, fighter)

  defp route(:coach, _account, _fighter), do: {:coach_onboarding, :coach_intent}
  defp route(:gym, _account, _fighter), do: {:gym_onboarding, :gym_intent}
  defp route(:sponsor, _account, _fighter), do: {:sponsor_application, :sponsor_intent}

  defp fighter_route(_intent, :completed), do: {:fighter_home, :fighter_onboarding_completed}

  defp fighter_route(_intent, :in_progress),
    do: {:fighter_onboarding, :fighter_onboarding_in_progress}

  defp fighter_route(:fighter, :not_started),
    do: {:fighter_onboarding, :fighter_onboarding_not_started}

  defp fighter_route(nil, :not_started), do: {:role_selection, :no_role_started}

  # Mandatory: the client goes here even when it holds a safe returnTo; the
  # returnTo is kept as a continuation and re-resolved afterwards.
  defp mandatory?(destination), do: destination in [:account_registration, :fighter_onboarding]

  # Only capabilities backed by a real domain. Coach, Gym and Sponsor
  # workspaces do not exist yet, so they are never reported.
  defp capabilities(:completed), do: [:fighter]
  defp capabilities(_fighter), do: []

  defp cast_intent(params) do
    changeset =
      {%{}, %{intent: :string}}
      |> cast(params, [:intent], empty_values: [nil, ""])
      |> validate_inclusion(:intent, Enum.map(@intents, &Atom.to_string/1))

    case apply_action(changeset, :resolve) do
      {:ok, %{intent: intent}} when is_binary(intent) -> {:ok, String.to_existing_atom(intent)}
      {:ok, _none} -> {:ok, nil}
      {:error, _changeset} = error -> error
    end
  end
end
