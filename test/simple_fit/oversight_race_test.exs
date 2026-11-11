defmodule SimpleFit.OversightRaceTest do
  @moduledoc """
  SF-123 under real commits, on separate connections outside the SQL sandbox:

  * a gym's detail is read in one snapshot, so counts read by different queries agree
    while staff and members change concurrently (with a deterministic negative
    control: the same reads outside a snapshot see a commit land between them);
  * a revoked permission refuses every read that starts after the revocation
    committed, while reads run concurrently;
  * a failed audit insert fails the read: no data leaves unrecorded.

  SF-123 adds no intervention, so there is no decision, replay or confirmation race
  to test here. Each test empties the operator tables with TRUNCATE (append-only for
  the application) on this disposable test database and deletes the users it made.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.OperatorHelpers

  import SimpleFit.GymHelpers,
    only: [registered!: 1, live_session!: 1, completed_gym!: 1, staff!: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{Gym, Member, StaffMembership}
  alias SimpleFit.{Operators, Repo}
  alias SimpleFit.Operators.{Operator, Overview}

  @tables ~w(operator_action_confirmations operator_audit_events operator_operations
             operator_ceremonies operator_permission_grants operator_step_ups
             operator_webauthn_challenges operator_credentials platform_operators)
  @all ~w(gyms.read coaches.read fighters.read operators.manage)

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    previous = Application.get_env(:simple_fit, Overview)
    Application.put_env(:simple_fit, Overview, snapshot: true)
    {:ok, users} = Agent.start(fn -> [] end)
    {:ok, gyms} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Application.put_env(:simple_fit, Overview, previous)
      Sandbox.mode(Repo, :auto)
      Repo.query!("ALTER TABLE operator_audit_events DROP CONSTRAINT IF EXISTS sf123_audit_fails")
      truncate!()
      gym_ids = Agent.get(gyms, & &1)
      cleanup_gyms!(gym_ids)
      Repo.delete_all(from(u in User, where: u.id in ^Agent.get(users, & &1)))
      Repo.delete_all("auth_rate_limits")
      Repo.delete_all("rate_limit_events")
      untrust_ceremony_keys!()
      Agent.stop(users)
      Agent.stop(gyms)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users, gyms: gyms, founder: founder!(users)}
  end

  defp truncate!, do: Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")

  # Gyms are never deleted by the application; the fixtures go with their rows.
  defp cleanup_gyms!([]), do: :ok

  defp cleanup_gyms!(ids) do
    Repo.query!("SET session_replication_role = replica")

    for table <- ~w(gym_members gym_staff_memberships gym_locations gym_audit_events gyms) do
      column = if table == "gyms", do: "id", else: "gym_id"
      Repo.query!("DELETE FROM #{table} WHERE #{column} = ANY($1)", [Enum.map(ids, &dump/1)])
    end

    Repo.query!("SET session_replication_role = DEFAULT")
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp track(agent, %{id: id} = record) do
    Agent.update(agent, &[id | &1])
    record
  end

  defp founder!(users) do
    user = track(users, registered!("founder"))
    session = live_session!(user)
    op = bootstrap!(user, @all)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

  defp reader!(founder, users, permissions) do
    user = track(users, registered!("reader"))
    session = live_session!(user)

    {:ok, _} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => permissions})
      )

    [k | _] = enroll!(user, session)
    _ = step_up!(user, session, k)
    %{user: user, session: session}
  end

  defp read_gym(o, id),
    do: Operators.get_gym(o.user, o.session, id, %{"reason_code" => "support_request"})

  # A coach becomes a member in one transaction: their coach staff membership ends and
  # an active gym membership begins, so `coaches + active members` never changes.
  defp coach_to_member!(gym_id, user_id) do
    {:ok, _} =
      Repo.transaction(fn ->
        now = DateTime.utc_now()

        {1, _} =
          Repo.update_all(
            from(s in StaffMembership,
              where: s.gym_id == ^gym_id and s.user_id == ^user_id and s.status == :active
            ),
            set: [status: :ended, ended_at: now, ended_reason: :left, updated_at: now]
          )

        Repo.insert!(%Member{
          gym_id: gym_id,
          user_id: user_id,
          status: :active,
          joined_via: :join_code,
          auto_approved: true,
          requested_at: now,
          activated_at: now
        })
      end)
  end

  test "a gym's detail is one snapshot: counts from different queries always agree", %{
    founder: founder,
    users: users,
    gyms: gyms
  } do
    owner = track(users, registered!("owner"))
    gym = track(gyms, completed_gym!(owner))
    coaches = for _ <- 1..30, do: track(users, registered!("coach"))
    for coach <- coaches, do: staff!(gym.id, coach, :coach)

    writer = Task.async(fn -> for coach <- coaches, do: coach_to_member!(gym.id, coach.id) end)

    readers =
      for _ <- 1..4 do
        Task.async(fn ->
          for _ <- 1..20 do
            {:ok, view} = read_gym(founder, gym.id)
            view.staff.coach + view.members.active
          end
        end)
      end

    Task.await(writer, 30_000)
    sums = Enum.flat_map(readers, &Task.await(&1, 30_000))

    assert length(sums) == 80
    assert Enum.uniq(sums) == [30]

    {:ok, final} = read_gym(founder, gym.id)
    assert final.staff.coach == 0 and final.members.active == 30
  end

  test "a commit between two reads isn't seen in the snapshot; without it, it is", %{
    users: users,
    gyms: gyms
  } do
    owner = track(users, registered!("owner"))
    gym = track(gyms, completed_gym!(owner))
    [first, second] = for _ <- 1..2, do: track(users, registered!("coach"))
    for coach <- [first, second], do: staff!(gym.id, coach, :coach)

    move = fn coach ->
      Task.async(fn -> coach_to_member!(gym.id, coach.id) end) |> Task.await()
    end

    {before, later} =
      Overview.snapshot(fn ->
        view = SimpleFit.Gyms.oversight_view(gym.id)
        move.(first)
        {view, SimpleFit.Gyms.oversight_view(gym.id)}
      end)

    assert later.staff == before.staff and later.members == before.members

    # The negative control: outside a snapshot the second read sees the commit.
    Application.put_env(:simple_fit, Overview, snapshot: false)

    {before, later} =
      Overview.snapshot(fn ->
        view = SimpleFit.Gyms.oversight_view(gym.id)
        move.(second)
        {view, SimpleFit.Gyms.oversight_view(gym.id)}
      end)

    assert later.staff.coach == before.staff.coach - 1
    assert later.members.active == before.members.active + 1
  end

  test "a revoked permission refuses every read that starts after the revocation commits", %{
    founder: founder,
    users: users,
    gyms: gyms
  } do
    reader = reader!(founder, users, ["gyms.read"])
    owner = track(users, registered!("owner"))
    gym = track(gyms, completed_gym!(owner))
    operator_id = Repo.one!(from(o in Operator, where: o.user_id == ^reader.user.id)).id
    {:ok, revoked_at} = Agent.start(fn -> nil end)

    readers =
      for _ <- 1..3 do
        Task.async(fn ->
          for _ <- 1..40 do
            started = System.monotonic_time()
            {started, read_gym(reader, gym.id)}
          end
        end)
      end

    Process.sleep(20)

    {:ok, _} =
      act(founder.user, founder.session, "operator.permission.revoke", operator_id, %{
        "permission" => "gyms.read"
      })

    Agent.update(revoked_at, fn _ -> System.monotonic_time() end)
    reads = Enum.flat_map(readers, &Task.await(&1, 30_000))
    revoked = Agent.get(revoked_at, & &1)

    after_revocation = Enum.filter(reads, fn {started, _} -> started > revoked end)
    assert Enum.all?(after_revocation, &match?({_, {:error, :forbidden}}, &1))
    assert Enum.all?(reads, &(match?({_, {:ok, _}}, &1) or match?({_, {:error, :forbidden}}, &1)))
    assert {:error, :forbidden} = read_gym(reader, gym.id)
  end

  test "a failed audit fails the read: nothing is returned unrecorded", %{
    founder: founder,
    users: users,
    gyms: gyms
  } do
    owner = track(users, registered!("owner"))
    gym = track(gyms, completed_gym!(owner))

    Repo.query!(
      "ALTER TABLE operator_audit_events ADD CONSTRAINT sf123_audit_fails " <>
        "CHECK (action <> 'gym.viewed') NOT VALID"
    )

    assert_raise Ecto.ConstraintError, ~r/sf123_audit_fails/, fn -> read_gym(founder, gym.id) end

    Repo.query!("ALTER TABLE operator_audit_events DROP CONSTRAINT sf123_audit_fails")
    assert {:ok, %{id: id}} = read_gym(founder, gym.id)
    assert id == gym.id
    assert Repo.exists?(from(g in Gym, where: g.id == ^gym.id))
  end
end
