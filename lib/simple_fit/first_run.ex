defmodule SimpleFit.FirstRun do
  @moduledoc """
  One-time first-run experiences (ADR 0018): whether a user should still be
  offered an experience, such as the Fighter web tour, and how they left it.

  It stores only the outcome (`SimpleFit.FirstRun.Outcome`). Everything else
  is derived on every read:

    * `:unavailable` - the user cannot have the experience yet. The Fighter
      web tour and the Fighter mobile introduction need a completed Fighter
      onboarding (ADR 0015), which itself needs a completed account
      registration (ADR 0016).
    * `:pending` - available, and no outcome is recorded.
    * `:completed` / `:dismissed` - the recorded outcome. It is final: a
      dismissed tour is never offered again, and recording again (the same or
      the other outcome, from another tab or device) keeps the first.

  Presentation is not onboarding: completing Fighter onboarding records
  nothing here, and nothing here changes registration, onboarding or entry
  resolution (ADR 0017). Every function acts on the authenticated user it is
  given.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.Fighters
  alias SimpleFit.FirstRun.Outcome
  alias SimpleFit.Repo

  @type status :: :unavailable | :pending | Outcome.outcome()
  @type state :: %{
          experience: Outcome.experience(),
          status: status(),
          recorded_at: DateTime.t() | nil
        }

  @doc "The experiences the client can ask for."
  @spec experiences() :: [Outcome.experience()]
  defdelegate experiences(), to: Outcome

  @doc "The state of every experience for the user."
  @spec list_experiences(User.t()) :: [state()]
  def list_experiences(%User{id: user_id} = user) when is_binary(user_id) do
    recorded =
      Repo.all(from(o in Outcome, where: o.user_id == ^user_id))
      |> Map.new(&{&1.experience, &1})

    Enum.map(experiences(), &state(&1, available?(user, &1), recorded[&1]))
  end

  @doc """
  Records how the user left an experience (`%{"outcome" => "completed" |
  "dismissed"}`) and returns its state. The first outcome recorded is kept:
  recording again returns it unchanged.

  Errors: `:not_found` for an unknown experience, `:conflict` while it is
  unavailable to the user, a changeset for an invalid outcome.
  """
  @spec record_outcome(User.t(), String.t(), map()) ::
          {:ok, state()} | {:error, :not_found | :conflict | Ecto.Changeset.t()}
  def record_outcome(%User{id: user_id} = user, experience, attrs)
      when is_binary(user_id) and is_binary(experience) and is_map(attrs) do
    with {:ok, experience} <- parse_experience(experience),
         changeset = Outcome.record_changeset(new(user_id, experience), attrs, now()),
         {:ok, _} <- validate(changeset),
         :ok <- require_available(user, experience) do
      # A concurrent or repeated request finds the row already there.
      {:ok, _} =
        Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:user_id, :experience])

      stored =
        Repo.one!(
          from(o in Outcome, where: o.user_id == ^user_id and o.experience == ^experience)
        )

      {:ok, state(experience, true, stored)}
    end
  end

  defp parse_experience(value) do
    case Enum.find(experiences(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :not_found}
      experience -> {:ok, experience}
    end
  end

  defp validate(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp validate(changeset), do: {:error, changeset}

  defp require_available(user, experience) do
    if available?(user, experience), do: :ok, else: {:error, :conflict}
  end

  # Both Fighter experiences need a completed Fighter onboarding. Each keeps
  # its own outcome: finishing the web tour says nothing about the mobile
  # introduction, and the other way round.
  defp available?(user, experience)
       when experience in [:fighter_web_tour, :fighter_mobile_first_run] do
    user |> Fighters.get_profile() |> Fighters.onboarding_status() == :completed
  end

  # A recorded outcome stays final even if availability were ever to change.
  defp state(experience, _available?, %Outcome{outcome: outcome, recorded_at: at}),
    do: %{experience: experience, status: outcome, recorded_at: at}

  defp state(experience, true, nil),
    do: %{experience: experience, status: :pending, recorded_at: nil}

  defp state(experience, false, nil),
    do: %{experience: experience, status: :unavailable, recorded_at: nil}

  defp new(user_id, experience), do: %Outcome{user_id: user_id, experience: experience}

  defp now, do: DateTime.utc_now()
end
