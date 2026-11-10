defmodule SimpleFit.Sponsors.FirstRun do
  @moduledoc """
  The partner portal first run (SF-119; SRW1 welcome, SRW2 tour): one member's
  introduction to one sponsor organization's portal, as the gym first run (SF-90)
  and ADR 0018. Internal to `SimpleFit.Sponsors`.

  ## What is stored

  Only explicit actions, per organization and member (`SponsorFirstRun`): started,
  then `completed` (finished) or `dismissed` (skipped or ended). An outcome is final:
  it never reopens, repeating it returns the same state, and the other outcome is a
  conflict. Tour steps, highlights and replays are client-only. Another organization,
  or another member of this one, starts fresh. Nothing here grants, restores or
  changes access: the first run is presentation.

  ## Who

  Every active member of the organization (any role): the tour shows what each role
  can see. Anyone else, including revoked or suspended members and other
  organizations' members, gets `:not_found`, as for every organization route
  (ADR 0030). A suspended organization stays readable by its members (ADR 0033) and
  answers `status: unavailable`; a transition there is a conflict
  (`organization_status: "suspended"`). A closed organization is not found.

  ## Locks

  Every call share-locks the organization, then the membership (the order of
  `Sponsors.lock_workspace/2` and `Sponsors.Provisioning`), then locks the first-run
  row for update. A suspension or revocation therefore commits entirely before or
  after a transition, and two transitions of one member in one organization
  serialize on the row.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.Accounts.User
  alias SimpleFit.Repo
  alias SimpleFit.Sponsors.{Membership, Organization, SponsorFirstRun}

  @type status :: :unavailable | :not_started | :in_progress | :completed | :dismissed
  @type action :: :start | :complete | :dismiss

  @type state :: %{
          sponsor_id: Ecto.UUID.t(),
          status: status(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          dismissed_at: DateTime.t() | nil
        }

  @type error :: :not_found | {:conflict, map()} | Changeset.t()

  @doc "The viewer's first run in the organization."
  @spec get(User.t(), term()) :: {:ok, state()} | {:error, :not_found}
  def get(%User{id: user_id} = user, sponsor_id) when is_binary(user_id) do
    Repo.transaction(fn ->
      case access(user, sponsor_id) do
        {:ok, organization} -> state(organization, fetch(organization.id, user_id))
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  An explicit transition (`attrs` is the request body and must be empty):

    * `:start` - not started -> in progress; repeated while in progress, the same
      state (the first `started_at` is kept);
    * `:complete` - not started or in progress -> `completed`; repeated, the same;
    * `:dismiss` - not started or in progress -> `dismissed`; repeated, the same.

  Any other transition is a conflict naming the kept outcome (`first_run:
  completed | dismissed`) and changes nothing; so is any transition in a suspended
  organization (`organization_status: suspended`).
  """
  @spec transition(User.t(), term(), action(), map()) :: {:ok, state()} | {:error, error()}
  def transition(%User{id: user_id} = user, sponsor_id, action, attrs)
      when is_binary(user_id) and action in [:start, :complete, :dismiss] and is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, organization} <- access(user, sponsor_id),
           :ok <- no_fields(attrs),
           :ok <- active(organization),
           {:ok, row} <- apply_action(organization.id, user_id, action, now()) do
        state(organization, row)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> tap(&emit(action, &1))
  end

  # -- Access --------------------------------------------------------------------

  # The organization (not closed), then the viewer's active membership, share-locked
  # in that order. Anything else is `:not_found`, never saying which.
  defp access(%User{id: user_id}, sponsor_id) do
    with {:ok, id} <- uuid(sponsor_id),
         %Organization{status: status} = organization when status != :closed <-
           Repo.one(from(o in Organization, where: o.id == ^id, lock: "FOR SHARE")),
         %Membership{} <-
           Repo.one(
             from(m in Membership,
               where: m.organization_id == ^id and m.user_id == ^user_id and m.status == :active,
               lock: "FOR SHARE"
             )
           ) do
      {:ok, organization}
    else
      _ -> {:error, :not_found}
    end
  end

  defp active(%Organization{status: :active}), do: :ok

  defp active(%Organization{status: status}),
    do: {:error, {:conflict, %{organization_status: Atom.to_string(status)}}}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  # -- Transitions ---------------------------------------------------------------

  defp apply_action(organization_id, user_id, action, now) do
    case lock(organization_id, user_id) do
      nil -> insert(organization_id, user_id, action, now)
      row -> decide(row, action, now)
    end
  end

  # The first action creates the row. A concurrent first action that commits first
  # makes this insert a no-op; the row is then read and decided like any existing one
  # (under its lock), so both requests agree.
  defp insert(organization_id, user_id, action, now) do
    fields =
      case action do
        :start -> [started_at: now]
        :complete -> [started_at: now, completed_at: now]
        :dismiss -> [dismissed_at: now]
      end

    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          user_id: user_id,
          inserted_at: now
        },
        Map.new([{:updated_at, now} | fields])
      )

    case Repo.insert_all(SponsorFirstRun, [row],
           on_conflict: :nothing,
           conflict_target: [:organization_id, :user_id],
           returning: true
         ) do
      {1, [inserted]} -> {:ok, inserted}
      {0, []} -> decide(lock(organization_id, user_id), action, now)
    end
  end

  defp decide(%SponsorFirstRun{completed_at: %DateTime{}} = row, :complete, _now), do: {:ok, row}
  defp decide(%SponsorFirstRun{dismissed_at: %DateTime{}} = row, :dismiss, _now), do: {:ok, row}

  defp decide(%SponsorFirstRun{completed_at: %DateTime{}}, _action, _now),
    do: {:error, {:conflict, %{first_run: "completed"}}}

  defp decide(%SponsorFirstRun{dismissed_at: %DateTime{}}, _action, _now),
    do: {:error, {:conflict, %{first_run: "dismissed"}}}

  defp decide(%SponsorFirstRun{} = row, :start, _now), do: {:ok, row}

  defp decide(%SponsorFirstRun{} = row, action, now) do
    field = if action == :complete, do: :completed_at, else: :dismissed_at
    # Never before the start, whatever the clocks of two app nodes say.
    at = if row.started_at, do: Enum.max([now, row.started_at], DateTime), else: now
    {:ok, row |> Changeset.change([{field, at}]) |> Repo.update!()}
  end

  defp lock(organization_id, user_id) do
    Repo.one(
      from(r in SponsorFirstRun,
        where: r.organization_id == ^organization_id and r.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp fetch(organization_id, user_id),
    do:
      Repo.one(
        from(r in SponsorFirstRun,
          where: r.organization_id == ^organization_id and r.user_id == ^user_id
        )
      )

  # Transitions take no input: the organization is the path's, the user the
  # session's. Any field (a forged `user_id`, a step) is refused.
  defp no_fields(attrs) when map_size(attrs) == 0, do: :ok

  defp no_fields(attrs) do
    changeset =
      attrs
      |> Map.keys()
      |> Enum.sort_by(&to_string/1)
      |> Enum.reduce(Changeset.change({%{}, %{}}), fn key, acc ->
        %{acc | errors: [{key, {"is not accepted", []}} | acc.errors], valid?: false}
      end)

    {:error, changeset}
  end

  # -- Views ---------------------------------------------------------------------

  defp state(%Organization{} = organization, row) do
    %{
      sponsor_id: organization.id,
      status: status(organization, row),
      started_at: row && row.started_at,
      completed_at: row && row.completed_at,
      dismissed_at: row && row.dismissed_at
    }
  end

  # A recorded outcome is final whatever happens to the organization later.
  defp status(_organization, %SponsorFirstRun{completed_at: %DateTime{}}), do: :completed
  defp status(_organization, %SponsorFirstRun{dismissed_at: %DateTime{}}), do: :dismissed
  defp status(%Organization{status: status}, _row) when status != :active, do: :unavailable
  defp status(_organization, nil), do: :not_started
  defp status(_organization, %SponsorFirstRun{}), do: :in_progress

  defp now, do: DateTime.utc_now()

  # Outcomes only: never an id or a name.
  defp emit(action, result) do
    outcome =
      case result do
        {:ok, _} -> :ok
        {:error, %Changeset{}} -> :invalid
        {:error, {:conflict, _}} -> :conflict
        {:error, reason} -> reason
      end

    :telemetry.execute([:simple_fit, :sponsors, :first_run, action], %{count: 1}, %{
      outcome: outcome
    })
  end
end
