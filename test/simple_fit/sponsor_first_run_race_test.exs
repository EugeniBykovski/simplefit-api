defmodule SimpleFit.SponsorFirstRunRaceTest do
  @moduledoc """
  SF-119 under true concurrency and real commits, outside the SQL sandbox (each call
  its own `Task`, connection and transaction): the partner portal first run racing
  itself, the other outcome, a revocation and a suspension. The rules checked every
  round: one row per organization and member, one final outcome that every request
  agrees on, and nothing recorded for someone whose access a committed change removed.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Repo, Sponsors}
  alias SimpleFit.Sponsors.{Provisioning, SponsorFirstRun}

  @tables ~w(sponsor_first_runs sponsor_organization_events sponsor_contacts
             sponsor_workspace_memberships sponsor_organizations)

  @rounds 12

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      truncate!()
      Repo.delete_all(from(u in User, where: u.id in ^Agent.get(users, & &1)))
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  defp truncate!, do: Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")

  defp user!(users, label) do
    user = registered!(label)
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

  defp rows(org_id, user_id),
    do:
      Repo.all(
        from(r in SponsorFirstRun, where: r.organization_id == ^org_id and r.user_id == ^user_id)
      )

  test "five tabs completing at once: one row, one completed_at, the same answer for all", c do
    for _ <- 1..@rounds do
      owner = user!(c.users, "race-complete")
      %{organization: org} = provision!(owner)

      results =
        concurrently(
          for _ <- 1..5,
              do: fn -> Sponsors.first_run_transition(owner, org.id, :complete, %{}) end
        )

      states = for {:ok, state} <- results, do: state
      assert length(states) == 5
      assert states |> Enum.map(& &1.completed_at) |> Enum.uniq() |> length() == 1
      assert [%SponsorFirstRun{completed_at: %DateTime{}}] = rows(org.id, owner.id)
    end
  end

  test "complete racing dismiss: exactly one outcome is kept; the loser is told which", c do
    for _ <- 1..@rounds do
      owner = user!(c.users, "race-outcome")
      %{organization: org} = provision!(owner)
      {:ok, _} = Sponsors.first_run_transition(owner, org.id, :start, %{})

      [a, b] =
        concurrently([
          fn -> Sponsors.first_run_transition(owner, org.id, :complete, %{}) end,
          fn -> Sponsors.first_run_transition(owner, org.id, :dismiss, %{}) end
        ])

      [row] = rows(org.id, owner.id)
      kept = if row.completed_at, do: "completed", else: "dismissed"
      assert is_nil(row.completed_at) != is_nil(row.dismissed_at)

      for result <- [a, b] do
        assert match?({:ok, %{status: status}} when status in [:completed, :dismissed], result) or
                 result == {:error, {:conflict, %{first_run: kept}}}
      end

      assert {:ok, %{status: status}} = Sponsors.get_first_run(owner, org.id)
      assert Atom.to_string(status) == kept
    end
  end

  test "revocation racing a completion: recorded before it, or nothing at all", c do
    owner = user!(c.users, "race-revoke-owner")
    %{organization: org} = provision!(owner)

    for _ <- 1..@rounds do
      member = user!(c.users, "race-revoke-member")
      membership = member!(org, member)

      [completed, {:ok, _}] =
        concurrently([
          fn -> Sponsors.first_run_transition(member, org.id, :complete, %{}) end,
          fn -> Provisioning.revoke_membership(fixture_authority(), membership.id, "left") end
        ])

      case completed do
        {:ok, %{status: :completed}} -> assert [_] = rows(org.id, member.id)
        {:error, :not_found} -> assert rows(org.id, member.id) == []
      end

      # Afterwards, nothing: no read, no write.
      assert {:error, :not_found} = Sponsors.get_first_run(member, org.id)
      assert {:error, :not_found} = Sponsors.first_run_transition(member, org.id, :dismiss, %{})
    end
  end

  test "suspension racing a start: started before it, or refused; never started after", c do
    for _ <- 1..@rounds do
      owner = user!(c.users, "race-suspend")
      %{organization: org} = provision!(owner)

      [started, {:ok, _}] =
        concurrently([
          fn -> Sponsors.first_run_transition(owner, org.id, :start, %{}) end,
          fn ->
            Provisioning.suspend_organization(fixture_authority(), org.id, "policy_concern")
          end
        ])

      case started do
        {:ok, %{status: :in_progress}} ->
          assert [_] = rows(org.id, owner.id)

        {:error, {:conflict, %{organization_status: "suspended"}}} ->
          assert rows(org.id, owner.id) == []
      end

      assert {:ok, %{status: :unavailable}} = Sponsors.get_first_run(owner, org.id)

      assert {:error, {:conflict, %{organization_status: "suspended"}}} =
               Sponsors.first_run_transition(owner, org.id, :complete, %{})
    end
  end

  test "two organizations at once: each keeps its own outcome", c do
    for _ <- 1..@rounds do
      user = user!(c.users, "race-two")
      %{organization: a} = provision!(user)
      %{organization: b} = provision!(user!(c.users, "race-two-owner"))
      _ = member!(b, user)

      _ =
        concurrently([
          fn -> Sponsors.first_run_transition(user, a.id, :complete, %{}) end,
          fn -> Sponsors.first_run_transition(user, b.id, :dismiss, %{}) end
        ])

      assert {:ok, %{status: :completed}} = Sponsors.get_first_run(user, a.id)
      assert {:ok, %{status: :dismissed}} = Sponsors.get_first_run(user, b.id)
    end
  end
end
