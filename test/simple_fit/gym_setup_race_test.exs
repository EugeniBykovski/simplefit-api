defmodule SimpleFit.GymSetupRaceTest do
  @moduledoc """
  Gym setup under true concurrency and real commits (SF-85), on separate
  database connections outside the SQL sandbox, so the gym-row lock order,
  the primary-location unique index and the completion trigger are
  exercised for real. Every test removes the gyms, audit events, limiter
  rows and users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Entry, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, Gym, GymLocation, StaffMembership}

  @address %{"country_code" => "PL", "city" => "Warsaw", "address_line" => "ul. Ząbkowska 31"}

  setup do
    Sandbox.mode(Repo, :auto)
    {:ok, users} = Agent.start(fn -> [] end)
    {:ok, gyms} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)

      gym_ids =
        Agent.get(gyms, & &1) ++
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
      Repo.delete_all("rate_limit_events")
      Enum.each([users, gyms], &Agent.stop/1)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users, gyms: gyms}
  end

  defp user!(ctx) do
    user = registered!("gym-setup-race")
    Agent.update(ctx.users, &[user.id | &1])
    user
  end

  defp ready_draft!(ctx) do
    owner = user!(ctx)
    gym = draft_gym!(owner)
    Agent.update(ctx.gyms, &[gym.id | &1])
    {:ok, _} = Gyms.put_primary_location(owner, gym.id, @address)
    {owner, gym}
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

  defp count(type, gym_id),
    do:
      Repo.aggregate(
        from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type),
        :count
      )

  test "completion racing discard: exactly one wins", ctx do
    for _ <- 1..8 do
      {owner, gym} = ready_draft!(ctx)

      [completed, discarded] =
        concurrently([
          fn -> Gyms.complete_setup(owner, gym.id) end,
          fn -> Gyms.discard_draft(owner, gym.id) end
        ])

      case Repo.get(Gym, gym.id) do
        %Gym{setup_status: :completed} ->
          assert {:ok, _, :completed} = completed
          assert discarded == {:error, {:conflict, %{setup_status: "completed"}}}
          assert count(:setup_completed, gym.id) == 1 and count(:draft_discarded, gym.id) == 0

        nil ->
          assert discarded == :ok
          assert completed == {:error, :not_found}
          assert count(:setup_completed, gym.id) == 0 and count(:draft_discarded, gym.id) == 1
      end
    end
  end

  test "two simultaneous completions: one completes, one finds it completed, one audit event",
       ctx do
    for _ <- 1..6 do
      {owner, gym} = ready_draft!(ctx)

      results = concurrently(for _ <- 1..2, do: fn -> Gyms.complete_setup(owner, gym.id) end)

      assert results |> Enum.map(&elem(&1, 2)) |> Enum.sort() == [:already_completed, :completed]
      assert count(:setup_completed, gym.id) == 1
      assert [_] = active_owners(gym.id)
    end
  end

  test "concurrent primary-location writes keep exactly one primary row", ctx do
    for _ <- 1..6 do
      owner = user!(ctx)
      gym = draft_gym!(owner)

      results =
        concurrently(
          for street <- ["ul. A 1", "ul. B 2", "ul. C 3", "ul. D 4"] do
            fn ->
              Gyms.put_primary_location(owner, gym.id, %{@address | "address_line" => street})
            end
          end
        )

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Repo.aggregate(from(l in GymLocation, where: l.gym_id == ^gym.id), :count) == 1
    end
  end

  test "two sessions editing different fields keep both changes", ctx do
    owner = user!(ctx)
    gym = draft_gym!(owner)

    [_, _] =
      concurrently([
        fn -> Gyms.update_setup(owner, gym.id, %{"tagline" => "From tab one"}) end,
        fn -> Gyms.update_setup(owner, gym.id, %{"phone" => "+48 600 000 000"}) end
      ])

    {:ok, setup} = Gyms.get_setup(owner, gym.id)
    assert {setup.tagline, setup.phone} == {"From tab one", "+48 600 000 000"}
    assert setup.revision == 3
  end

  test "two writes on one revision: one applies, the other is stale and changes nothing", ctx do
    for _ <- 1..6 do
      owner = user!(ctx)
      gym = draft_gym!(owner)

      results =
        concurrently(
          for name <- ["Name A", "Name B"] do
            fn ->
              Gyms.update_setup(owner, gym.id, %{"name" => name, "expected_revision" => 1})
            end
          end
        )

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, {:conflict, %{revision: "stale"}}})) == 1
      assert Repo.get!(Gym, gym.id).revision == 2
    end
  end

  test "completion racing a profile update: both apply in some order, still completed", ctx do
    for _ <- 1..6 do
      {owner, gym} = ready_draft!(ctx)

      [completed, updated] =
        concurrently([
          fn -> Gyms.complete_setup(owner, gym.id) end,
          fn -> Gyms.update_setup(owner, gym.id, %{"tagline" => "Racing"}) end
        ])

      assert {:ok, _, :completed} = completed
      assert {:ok, _} = updated
      assert %Gym{setup_status: :completed, tagline: "Racing"} = Repo.get!(Gym, gym.id)
    end
  end

  test "a manager's edit racing their revocation: applied before, or not found after", ctx do
    for _ <- 1..6 do
      owner = user!(ctx)
      gym = completed_gym!(owner)
      manager = user!(ctx)
      m = staff!(gym.id, manager, :manager)

      [edited, revoked] =
        concurrently([
          fn -> Gyms.update_setup(manager, gym.id, %{"tagline" => "Manager"}) end,
          fn -> Gyms.revoke_staff_membership(owner, gym.id, m.id) end
        ])

      assert {:ok, _} = revoked

      case edited do
        {:ok, _} -> assert Repo.get!(Gym, gym.id).tagline == "Manager"
        {:error, :not_found} -> assert Repo.get!(Gym, gym.id).tagline == nil
      end

      assert {:error, :not_found} = Gyms.update_setup(manager, gym.id, %{"tagline" => "Late"})
    end
  end

  test "an ownership transfer racing a setup update stays consistent", ctx do
    for _ <- 1..6 do
      owner = user!(ctx)
      gym = completed_gym!(owner)
      target = staff!(gym.id, user!(ctx), :manager)

      [transferred, updated] =
        concurrently([
          fn -> Gyms.transfer_ownership(owner, gym.id, target.id, :leave) end,
          fn -> Gyms.update_setup(owner, gym.id, %{"tagline" => "Old owner"}) end
        ])

      assert {:ok, _} = transferred
      assert match?({:ok, _}, updated) or updated == {:error, :not_found}
      assert [%{id: id}] = active_owners(gym.id)
      assert id == target.id
    end
  end

  test "the account-deletion guard racing completion: never ok after completion", ctx do
    for _ <- 1..6 do
      {owner, gym} = ready_draft!(ctx)

      [guard, completed] =
        concurrently([
          fn -> Gyms.check_account_deletion(owner) end,
          fn -> Gyms.complete_setup(owner, gym.id) end
        ])

      assert {:ok, _, :completed} = completed
      assert guard in [:ok, {:error, {:conflict, %{gym_ownership: "transfer_required"}}}]
      assert {:error, {:conflict, _}} = Gyms.check_account_deletion(owner)
    end
  end

  test "entry resolution during completion sees either state, never a partial one", ctx do
    for _ <- 1..6 do
      {owner, gym} = ready_draft!(ctx)

      [{:ok, entry}, {:ok, _, :completed}] =
        concurrently([
          fn -> Entry.resolve(owner, %{"intent" => "gym"}) end,
          fn -> Gyms.complete_setup(owner, gym.id) end
        ])

      assert {entry.destination, entry.gym_id} in [{:gym_onboarding, gym.id}, {:gym_home, gym.id}]
      {:ok, settled} = Entry.resolve(owner, %{"intent" => "gym"})
      assert settled.destination == :gym_home
    end
  end

  test "a replayed discard and a replayed create after discard", ctx do
    owner = user!(ctx)
    attrs = gym_attrs()
    {:ok, gym, :created} = Gyms.create_gym(owner, attrs, client_ip())

    assert :ok = Gyms.discard_draft(owner, gym.id)
    assert {:error, :not_found} = Gyms.discard_draft(owner, gym.id)

    # The key named a gym that no longer exists: a replay starts a new draft.
    assert {:ok, again, :created} = Gyms.create_gym(owner, attrs, client_ip())
    refute again.id == gym.id
    assert gyms_created_by(owner) == 1
  end
end
