defmodule SimpleFit.Fighters do
  @moduledoc """
  Fighter profiles and resumable Fighter onboarding (ADR 0015).

  A user becomes a fighter by onboarding as one; nothing here is created
  with the user (ADR 0009). The onboarding has three states, derived from
  stored facts rather than reported by clients:

    * `:not_started` - the user has no fighter profile;
    * `:in_progress` - a profile exists, completion is not recorded;
    * `:completed` - `onboarding_completed_at` is set. Only
      `complete_onboarding/1` sets it, and only when every required field is
      present (`FighterProfile.required_fields/0`); the database enforces the
      same invariant.

  Progress is saved as the fighter goes (`update_profile/2` accepts any subset
  of fields and creates the profile on the first save). Every function acts
  on the authenticated user it is given: a fighter only ever reads or changes
  their own profile.

  Results: `{:ok, value}` or `{:error, %Ecto.Changeset{}}` (rendered as
  `validation_error`, with `required` field codes for missing requirements and
  `already_exists` for a taken username).
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.Fighters.FighterProfile
  alias SimpleFit.Repo

  # Profile rows carry personal data (name, city, body data); Ecto's query log
  # (debug level) would print the parameters, so these queries are not logged
  # (ADR 0008).
  @unlogged [log: false]

  @doc "The user's fighter profile, or `nil` when Fighter onboarding has not started."
  @spec get_profile(User.t()) :: FighterProfile.t() | nil
  def get_profile(%User{id: user_id}) when is_binary(user_id) do
    Repo.one(from(p in FighterProfile, where: p.user_id == ^user_id), @unlogged)
  end

  @doc """
  Saves onboarding progress: any subset of `FighterProfile.editable_fields/0`
  (string or atom keys; `null` clears an optional field). The first save
  creates the profile. An invalid save changes nothing, and does not create a
  profile either.
  """
  @spec update_profile(User.t(), map()) ::
          {:ok, FighterProfile.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%User{id: user_id}, attrs) when is_binary(user_id) and is_map(attrs) do
    Repo.transaction(
      fn ->
        user_id
        |> lock_or_create_profile()
        |> FighterProfile.update_changeset(attrs)
        |> Repo.update(@unlogged)
        |> case do
          {:ok, profile} -> profile
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end,
      @unlogged
    )
  end

  @doc """
  Completes Fighter onboarding. Fails with a changeset carrying a `required`
  error for every missing requirement (all of them when there is no profile
  yet, which is then not created). Completing again is a no-op that keeps the
  original completion time.
  """
  @spec complete_onboarding(User.t()) ::
          {:ok, FighterProfile.t()} | {:error, Ecto.Changeset.t()}
  def complete_onboarding(%User{id: user_id} = user) when is_binary(user_id) do
    Repo.transaction(
      fn ->
        profile = lock_profile(user_id) || %FighterProfile{user_id: user.id}

        profile
        |> FighterProfile.complete_changeset(DateTime.utc_now())
        |> persist_completion()
        |> case do
          {:ok, profile} -> profile
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end,
      @unlogged
    )
  end

  @doc "See `FighterProfile.onboarding_status/1`."
  @spec onboarding_status(FighterProfile.t() | nil) :: :not_started | :in_progress | :completed
  defdelegate onboarding_status(profile), to: FighterProfile

  @doc "See `FighterProfile.missing_requirements/1`."
  @spec missing_requirements(FighterProfile.t() | nil) :: [atom()]
  defdelegate missing_requirements(profile), to: FighterProfile

  # A missing profile is never inserted by completion: without one, the
  # changeset is always invalid (every requirement is missing).
  defp persist_completion(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  defp persist_completion(%Ecto.Changeset{} = changeset), do: Repo.update(changeset, @unlogged)

  defp lock_profile(user_id) do
    Repo.one(
      from(p in FighterProfile, where: p.user_id == ^user_id, lock: "FOR UPDATE"),
      @unlogged
    )
  end

  # Concurrent first saves converge on one row: the insert is a no-op when the
  # profile already exists (unique user_id), then the row is locked for the
  # rest of the transaction.
  defp lock_or_create_profile(user_id) do
    now = DateTime.utc_now(:second)

    {_inserted, nil} =
      Repo.insert_all(
        FighterProfile,
        [%{id: Ecto.UUID.generate(), user_id: user_id, inserted_at: now, updated_at: now}],
        Keyword.merge(@unlogged, on_conflict: :nothing, conflict_target: :user_id)
      )

    lock_profile(user_id)
  end
end
