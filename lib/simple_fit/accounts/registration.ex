defmodule SimpleFit.Accounts.Registration do
  @moduledoc """
  Shared account registration (ADR 0016): basics and consents every user
  completes after authenticating, before any role-specific journey. Internal
  to `SimpleFit.Accounts`; call the context.

  States are derived, never stored or reported by clients:

    * `:not_started` - no account profile;
    * `:in_progress` - a profile without `registration_completed_at`;
    * `:complete` - `registration_completed_at` is set (only by `complete/1`).
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.{AccountProfile, Consents, User}
  alias SimpleFit.Repo

  @unlogged [log: false]

  @type status :: :not_started | :in_progress | :complete
  @type t :: %{
          profile: AccountProfile.t() | nil,
          consents: Consents.state(),
          status: status(),
          missing_requirements: [atom()]
        }

  @doc "The registration state of a user."
  @spec get(User.t()) :: t()
  def get(%User{id: user_id}) when is_binary(user_id) do
    profile = Repo.one(from(p in AccountProfile, where: p.user_id == ^user_id), @unlogged)
    build(profile, Consents.state(user_id))
  end

  @doc "Whether the user has completed account registration."
  @spec complete?(User.t()) :: boolean()
  def complete?(%User{id: user_id}) when is_binary(user_id) do
    Repo.exists?(
      from(p in AccountProfile,
        where: p.user_id == ^user_id and not is_nil(p.registration_completed_at)
      ),
      @unlogged
    )
  end

  @doc """
  Saves registration progress. The first save that persists something (a
  field or a consent decision) creates the profile; a save with nothing to
  persist creates nothing. An invalid save changes nothing.
  """
  @spec update(User.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%User{id: user_id} = user, attrs) when is_binary(user_id) and is_map(attrs) do
    case Repo.transaction(fn -> save_progress(user_id, attrs) end, @unlogged) do
      {:ok, _profile} -> {:ok, get(user)}
      {:error, :nothing_to_save} -> {:ok, get(user)}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  # Inside the transaction: the profile row is created if missing and locked,
  # then rolled back again when the save turns out to persist nothing.
  defp save_progress(user_id, attrs) do
    {created?, profile} = lock_or_create(user_id)
    changeset = AccountProfile.update_changeset(profile, attrs, Date.utc_today())
    state = Consents.state(user_id)
    records = Consents.records_for(user_id, changeset.changes, state, DateTime.utc_now())
    profile_changes = Map.drop(changeset.changes, [:accept_terms, :accept_privacy, :product_news])

    cond do
      not changeset.valid? -> Repo.rollback(changeset)
      created? and profile_changes == %{} and records == [] -> Repo.rollback(:nothing_to_save)
      true -> save(changeset, records)
    end
  end

  @doc """
  Completes registration: full name, an age of at least the minimum, and
  current acceptance of every required consent. Fails with a `required`
  error per missing item (creating nothing without a profile); completing
  again keeps the original completion time.
  """
  @spec complete(User.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def complete(%User{id: user_id} = user) when is_binary(user_id) do
    Repo.transaction(
      fn ->
        profile = lock(user_id) || %AccountProfile{user_id: user_id}
        missing_consents = user_id |> Consents.state() |> Consents.missing()

        changeset =
          AccountProfile.complete_changeset(
            profile,
            if(profile.registration_completed_at, do: [], else: missing_consents),
            Date.utc_today(),
            DateTime.utc_now()
          )

        cond do
          not changeset.valid? -> Repo.rollback(changeset)
          profile.id == nil -> Repo.rollback(changeset)
          true -> update!(changeset)
        end
      end,
      @unlogged
    )
    |> case do
      {:ok, _profile} -> {:ok, get(user)}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  defp build(profile, consents) do
    status =
      cond do
        profile == nil -> :not_started
        profile.registration_completed_at != nil -> :complete
        true -> :in_progress
      end

    missing =
      if status == :complete,
        do: [],
        else: AccountProfile.missing_fields(profile) ++ Consents.missing(consents)

    %{profile: profile, consents: consents, status: status, missing_requirements: missing}
  end

  defp save(changeset, records) do
    profile = update!(changeset)
    :ok = Consents.append(records)
    profile
  end

  defp update!(changeset) do
    case Repo.update(changeset, @unlogged) do
      {:ok, profile} -> profile
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp lock(user_id) do
    Repo.one(
      from(p in AccountProfile, where: p.user_id == ^user_id, lock: "FOR UPDATE"),
      @unlogged
    )
  end

  # Concurrent first saves converge on one row: the insert is a no-op when
  # the profile exists (unique user_id); the row is then locked for the rest
  # of the transaction, which also serializes consent decisions.
  defp lock_or_create(user_id) do
    now = DateTime.utc_now(:second)

    {inserted, nil} =
      Repo.insert_all(
        AccountProfile,
        [%{id: Ecto.UUID.generate(), user_id: user_id, inserted_at: now, updated_at: now}],
        Keyword.merge(@unlogged, on_conflict: :nothing, conflict_target: :user_id)
      )

    {inserted == 1, lock(user_id)}
  end
end
