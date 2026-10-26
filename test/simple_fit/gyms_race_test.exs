defmodule SimpleFit.GymsRaceTest do
  @moduledoc """
  Gyms under true concurrency and real commits (SF-83), on separate database
  connections outside the SQL sandbox, so advisory locks, row locks, unique
  indexes and the commit-time "exactly one active owner" trigger are
  exercised for real. Rows are committed: every test removes the gyms, audit
  events and users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, Gym, StaffMembership}

  setup do
    Sandbox.mode(Repo, :auto)
    Repo.delete_all("auth_rate_limits")
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)

      gym_ids =
        Repo.all(
          from(g in Gym,
            left_join: m in StaffMembership,
            on: m.gym_id == g.id,
            where: g.created_by_user_id in ^ids or m.user_id in ^ids,
            distinct: true,
            select: g.id
          )
        )

      Repo.delete_all(from(e in AuditEvent, where: e.gym_id in ^gym_ids))
      Repo.delete_all(from(g in Gym, where: g.id in ^gym_ids))
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all("auth_rate_limits")
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  defp user!(users) do
    user = registered!("gym-race")
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

  test "simultaneous creates with one key create one gym", %{users: users} do
    owner = user!(users)
    attrs = gym_attrs()

    results =
      concurrently(for _ <- 1..8, do: fn -> Gyms.create_gym(owner, attrs, client_ip()) end)

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :existing}, &1)) == 7
    assert results |> Enum.map(fn {:ok, v, _} -> v.id end) |> Enum.uniq() |> length() == 1
    assert gyms_created_by(owner) == 1
  end

  test "simultaneous first creates with different keys create one open draft", %{users: users} do
    owner = user!(users)

    results =
      concurrently(for _ <- 1..8, do: fn -> Gyms.create_gym(owner, gym_attrs(), client_ip()) end)

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :resumed}, &1)) == 7
    assert gyms_created_by(owner) == 1
    [gym] = Repo.all(from(g in Gym, where: g.created_by_user_id == ^owner.id))
    assert [_] = active_owners(gym.id)
  end

  test "the client limit holds under concurrency: exactly 20 of 25 creations", %{users: users} do
    ip = client_ip()
    owners = for _ <- 1..25, do: user!(users)

    results = concurrently(for o <- owners, do: fn -> Gyms.create_gym(o, gym_attrs(), ip) end)

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 20
    assert Enum.count(results, &match?({:error, {:rate_limited, _}}, &1)) == 5

    created =
      Repo.aggregate(
        from(g in Gym, where: g.created_by_user_id in ^Enum.map(owners, & &1.id)),
        :count
      )

    assert created == 20
  end

  test "simultaneous transfers to two people leave exactly one owner", %{users: users} do
    for _ <- 1..6 do
      owner = user!(users)
      gym = completed_gym!(owner)
      a = staff!(gym.id, user!(users), :manager)
      b = staff!(gym.id, user!(users), :coach)

      results =
        concurrently([
          fn -> Gyms.transfer_ownership(owner, gym.id, a.id, :stay_as_manager) end,
          fn -> Gyms.transfer_ownership(owner, gym.id, b.id, :stay_as_manager) end
        ])

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      # The loser runs after the winner committed: the actor is a manager now.
      assert Enum.count(results, &(&1 == {:error, :forbidden})) == 1
      assert [%StaffMembership{id: id}] = active_owners(gym.id)
      assert id in [a.id, b.id]
    end
  end

  test "a transfer racing the revocation of its target stays consistent", %{users: users} do
    for _ <- 1..6 do
      owner = user!(users)
      gym = completed_gym!(owner)
      manager = user!(users)
      staff!(gym.id, manager, :manager)
      target = staff!(gym.id, user!(users), :coach)

      [transferred, revoked] =
        concurrently([
          fn -> Gyms.transfer_ownership(owner, gym.id, target.id, :leave) end,
          fn -> Gyms.revoke_staff_membership(manager, gym.id, target.id) end
        ])

      [owner_row] = active_owners(gym.id)

      case transferred do
        {:ok, _} ->
          # The target became owner first; nobody revokes an owner.
          assert revoked == {:error, :forbidden}
          assert owner_row.id == target.id

        {:error, :not_found} ->
          # The revocation committed first; the transfer found no target.
          assert {:ok, %StaffMembership{status: :ended}} = revoked
          assert owner_row.user_id == owner.id
      end
    end
  end

  test "a revoked staff member's in-flight access ends with the revocation", %{users: users} do
    owner = user!(users)
    gym = completed_gym!(owner)
    coach = user!(users)
    m = staff!(gym.id, coach, :coach)

    assert {:ok, _} = Gyms.authorize(coach, gym.id, :record_check_in)
    {:ok, _} = Gyms.revoke_staff_membership(owner, gym.id, m.id)
    assert {:error, :not_found} = Gyms.authorize(coach, gym.id, :record_check_in)
  end

  describe "database invariants at commit" do
    # The rejected commit drops its connection, which the pool logs.
    @tag :capture_log
    test "a transaction that leaves a gym without an owner is rejected", %{users: users} do
      owner = user!(users)
      gym = completed_gym!(owner)
      [owner_row] = active_owners(gym.id)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.update_all(from(m in StaffMembership, where: m.id == ^owner_row.id),
              set: [status: :ended, ended_at: DateTime.utc_now(), ended_reason: :removed]
            )
          end)
        end

      assert error.postgres.constraint == "gyms_single_active_owner"
      assert [_] = active_owners(gym.id)
    end

    # The rejected commit drops its connection, which the pool logs.
    @tag :capture_log
    test "a gym inserted without an owner is rejected", %{users: users} do
      owner = user!(users)

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%Gym{
            name: "Ownerless",
            gym_type: :boxing_gym,
            setup_status: :completed,
            created_by_user_id: owner.id,
            client_request_id: Ecto.UUID.generate()
          })
        end)
      end

      assert gyms_created_by(owner) == 0
    end

    test "a second active owner is rejected immediately", %{users: users} do
      owner = user!(users)
      gym = completed_gym!(owner)
      other = user!(users)

      assert_raise Ecto.ConstraintError, ~r/gym_staff_one_active_owner_index/, fn ->
        Repo.insert!(%StaffMembership{
          gym_id: gym.id,
          user_id: other.id,
          role: :owner,
          status: :active
        })
      end
    end

    test "a completed setup never returns to draft; audit events are append-only", %{users: users} do
      owner = user!(users)
      gym = completed_gym!(owner)

      assert_raise Postgrex.Error, ~r/completed gym setup is final/, fn ->
        Repo.update_all(from(g in Gym, where: g.id == ^gym.id), set: [setup_status: :draft])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(e in AuditEvent, where: e.gym_id == ^gym.id),
          set: [reason: :removed]
        )
      end
    end

    test "an ended membership is final", %{users: users} do
      owner = user!(users)
      gym = completed_gym!(owner)
      m = staff!(gym.id, user!(users), :coach)
      {:ok, _} = Gyms.revoke_staff_membership(owner, gym.id, m.id)

      assert_raise Postgrex.Error, ~r/ended gym staff membership is final/, fn ->
        Repo.update_all(from(s in StaffMembership, where: s.id == ^m.id),
          set: [status: :active, ended_at: nil, ended_reason: nil]
        )
      end
    end
  end

  describe "user deletion (D-G26)" do
    test "an owner's user row cannot be deleted; the gym keeps its owner", %{users: users} do
      owner = user!(users)
      gym = completed_gym!(owner)

      assert {:error, {:conflict, _}} = Gyms.check_account_deletion(owner)

      assert_raise Postgrex.Error, ~r/user_present_while_active/, fn ->
        Repo.delete_all(from(u in User, where: u.id == ^owner.id))
      end

      assert [%{user_id: user_id}] = active_owners(gym.id)
      assert user_id == owner.id
    end

    test "deleting a former staff member keeps the gym and the history", %{users: users} do
      owner = user!(users)
      gym = completed_gym!(owner)
      former = registered!("gym-race-former")
      m = staff!(gym.id, former, :coach)
      {:ok, _} = Gyms.revoke_staff_membership(owner, gym.id, m.id)

      {1, _} = Repo.delete_all(from(u in User, where: u.id == ^former.id))

      ended = Repo.get!(StaffMembership, m.id)
      assert ended.user_id == nil and ended.status == :ended
      assert Repo.get(Gym, gym.id)
      assert [_] = active_owners(gym.id)
    end

    test "deleting an unrelated user touches no gym", %{users: users} do
      owner = user!(users)
      gym = completed_gym!(owner)
      bystander = registered!("gym-race-bystander")
      before = Repo.aggregate(StaffMembership, :count)

      {1, _} = Repo.delete_all(from(u in User, where: u.id == ^bystander.id))

      assert Repo.aggregate(StaffMembership, :count) == before
      assert Repo.get(Gym, gym.id)
    end
  end
end
