defmodule SimpleFit.Coaching.Activation do
  @moduledoc """
  The one way a Coach–Fighter relationship becomes active (ADR 0021): the
  trusted last step of a fighter's explicit acceptance.

  Internal to `SimpleFit.Coaching`. Its only caller is the fighter-side
  acceptance of a coach invitation (the Invitation task, same context),
  which first verifies, binds to the signed-in fighter and consumes the
  one-time invitation token, and checks that the fighter accepted exactly
  the disclosure version they were shown. No controller, endpoint or other
  context calls it: a coach can never create a relationship, and an
  authenticated caller can never create one by naming two profiles.

  `activate/3` checks, inside one transaction (joining the caller's):

    1. new sharing is enabled (`SimpleFit.Coaching.access_enabled?/0`);
    2. the disclosure version is configured (`SimpleFit.Coaching.Disclosure`);
    3. the accepting user has a completed fighter profile;
    4. the coach profile exists and is completed;
    5. the coach and the fighter are different users.

  It then inserts the active relationship, or returns the pair's existing
  active one (concurrent or repeated acceptances converge on one row, which
  keeps the disclosure version accepted first). The database enforces the
  same invariants (one active relationship per pair, completed profiles, no
  self-coaching), so a failed check can never leave a partial relationship.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaches, Coaching, Fighters, Repo}
  alias SimpleFit.Coaching.{Disclosure, Relationship}

  @unlogged [log: false]

  @type error ::
          :sharing_disabled
          | :disclosure_not_offered
          | :fighter_not_completed
          | :coach_unavailable
          | :self_coaching

  @doc "Activates the relationship accepted by `fighter_user` (see the module doc)."
  @spec activate(Ecto.UUID.t(), User.t(), String.t()) ::
          {:ok, Relationship.t(), :created | :existing} | {:error, error()}
  def activate(coach_profile_id, %User{id: user_id} = fighter_user, disclosure_version)
      when is_binary(coach_profile_id) and is_binary(user_id) do
    with :ok <- check(Coaching.access_enabled?(), :sharing_disabled),
         :ok <- check(Disclosure.offered?(disclosure_version), :disclosure_not_offered),
         {:ok, fighter} <- completed(Fighters.get_profile(fighter_user), :fighter_not_completed),
         {:ok, coach} <-
           completed(Coaches.get_profile_by_id(coach_profile_id), :coach_unavailable),
         :ok <- check(coach.user_id != user_id, :self_coaching) do
      Repo.transaction(
        fn -> insert_or_existing(coach, fighter, disclosure_version) end,
        @unlogged
      )
      |> case do
        {:ok, {relationship, outcome}} ->
          :telemetry.execute([:simple_fit, :coaching, :relationship, :activated], %{count: 1}, %{
            outcome: outcome
          })

          {:ok, relationship, outcome}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp completed(%{onboarding_completed_at: %DateTime{}} = profile, _reason), do: {:ok, profile}
  defp completed(_profile, reason), do: {:error, reason}

  # The pair's active relationship is locked (FOR SHARE) when it exists, so
  # an end of it waits until this acceptance commits and the outcome stays
  # true. Otherwise a new one is inserted; a concurrent acceptance of the
  # same pair waits on the partial unique index and inserts nothing, and the
  # row it conflicted with is then locked and returned. If that row was ended
  # in between, the insert is simply tried again (bounded).
  defp insert_or_existing(coach, fighter, version, attempts \\ 3)

  defp insert_or_existing(_coach, _fighter, _version, 0),
    do: raise("could not settle the active relationship of a pair")

  defp insert_or_existing(coach, fighter, version, attempts) do
    case lock_active(coach, fighter) do
      %Relationship{} = existing ->
        {existing, :existing}

      nil ->
        case insert(coach, fighter, version) do
          {1, [created]} -> {created, :created}
          {0, []} -> insert_or_existing(coach, fighter, version, attempts - 1)
        end
    end
  end

  defp lock_active(coach, fighter) do
    Repo.one(
      from(r in Relationship,
        where:
          r.coach_profile_id == ^coach.id and r.fighter_profile_id == ^fighter.id and
            r.status == :active,
        lock: "FOR SHARE"
      ),
      @unlogged
    )
  end

  defp insert(coach, fighter, version) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Relationship,
      [
        %{
          id: Ecto.UUID.generate(),
          coach_profile_id: coach.id,
          fighter_profile_id: fighter.id,
          status: :active,
          disclosure_version: version,
          started_at: now,
          inserted_at: now,
          updated_at: now
        }
      ],
      Keyword.merge(@unlogged,
        on_conflict: :nothing,
        conflict_target:
          {:unsafe_fragment, "(coach_profile_id, fighter_profile_id) WHERE status = 'active'"},
        returning: true
      )
    )
  end
end
