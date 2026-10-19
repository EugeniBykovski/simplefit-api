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

    1. sharing is ready (`SimpleFit.Coaching.sharing_ready?/0`: the gate,
       a valid registry, a published current disclosure and data rules);
    2. the disclosure version is the published current one
       (`SimpleFit.Coaching.Disclosure`);
    3. the accepting user has a completed fighter profile;
    4. the fighter is at least 18 (SF-71 L-14; `eligible?/2`);
    5. the coach profile exists and is completed;
    6. the coach and the fighter are different users.

  ## Age (18+)

  Coach–Fighter connections need the fighter to be 18 or older; account
  registration stays 16+ (ADR 0016). The age comes only from the account
  profile's date of birth, which is immutable once registration is
  complete; a missing date is not eligible. It is evaluated for the calendar
  date in UTC−12, the last time zone to reach any date, so nobody is
  treated as 18 before their 18th birthday wherever they are; birthdays
  count in whole calendar years (`AccountProfile.age/2`, as at registration:
  a 29 February birthday is reached on 1 March in common years). The coach
  never learns the reason or the age.

  It then inserts the active relationship, or returns the pair's existing
  active one (concurrent or repeated acceptances converge on one row, which
  keeps the disclosure version accepted first). The database enforces the
  same invariants (one active relationship per pair, completed profiles, no
  self-coaching), so a failed check can never leave a partial relationship.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{AccountProfile, User}
  alias SimpleFit.{Coaches, Coaching, Fighters, Repo}
  alias SimpleFit.Coaching.{Disclosure, Relationship}

  @unlogged [log: false]

  @type error ::
          :sharing_disabled
          | :disclosure_not_offered
          | :fighter_not_completed
          | :fighter_too_young
          | :coach_unavailable
          | :self_coaching

  @doc "Activates the relationship accepted by `fighter_user` (see the module doc)."
  @spec activate(Ecto.UUID.t(), User.t(), String.t()) ::
          {:ok, Relationship.t(), :created | :existing} | {:error, error()}
  def activate(coach_profile_id, %User{id: user_id} = fighter_user, disclosure_version)
      when is_binary(coach_profile_id) and is_binary(user_id) do
    with :ok <- check(Coaching.sharing_ready?(), :sharing_disabled),
         :ok <- check(Disclosure.offered?(disclosure_version), :disclosure_not_offered),
         {:ok, fighter} <- completed(Fighters.get_profile(fighter_user), :fighter_not_completed),
         :ok <- check(eligible?(fighter_user, eligibility_date()), :fighter_too_young),
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

  @minimum_age 18

  @doc "The minimum age of a fighter for a Coach–Fighter connection."
  @spec minimum_age() :: pos_integer()
  def minimum_age, do: @minimum_age

  @doc """
  Whether `user` is at least `minimum_age/0` on `date`, from their account
  profile's date of birth only (no date: not eligible).
  """
  @spec eligible?(User.t(), Date.t()) :: boolean()
  def eligible?(%User{} = user, %Date{} = date) do
    case Accounts.date_of_birth(user) do
      %Date{} = born -> AccountProfile.age(born, date) >= @minimum_age
      nil -> false
    end
  end

  @doc "Today in UTC−12: the date on which eligibility is evaluated."
  @spec eligibility_date() :: Date.t()
  def eligibility_date,
    do: DateTime.utc_now() |> DateTime.add(-12 * 3600) |> DateTime.to_date()

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
