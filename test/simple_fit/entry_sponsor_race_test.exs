defmodule SimpleFit.EntrySponsorRaceTest do
  @moduledoc """
  SF-117 under true concurrency and real commits, outside the SQL sandbox (each
  call is its own `Task`, so its own pooled connection and transaction): sponsor
  context choices and entry resolution racing membership revocation, organization
  suspension and reinstatement, provisioning (what an approval commits) and
  logout. The rule checked every round: once a change has committed, no later
  request is authorized by anything the change forbids, whatever a resolver
  snapshot, a remembered choice or an old session said before it.

  Sponsor tables are append-only for the application, so each test empties them
  with TRUNCATE on this disposable test database and deletes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Entry, Repo, Sponsors}
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Sponsors.Provisioning

  @tables ~w(sponsor_organization_events sponsor_contacts sponsor_workspace_memberships
             sponsor_organizations)

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

  defp choose(user, org_id) do
    case Entry.record_context_choice(user, %{"context" => "sponsor", "sponsor_id" => org_id}) do
      {:ok, _choice} -> :ok
      {:error, _} = error -> error
    end
  end

  defp sponsor_home?(user, org_id) do
    {:ok, entry} = Entry.resolve(user, %{"intent" => "sponsor"})
    entry.destination == :sponsor_home and entry.sponsor_id == org_id
  end

  defp choice_for(user) do
    Repo.one(
      from(c in ContextChoice, where: c.user_id == ^user.id, select: c.sponsor_organization_id)
    )
  end

  test "membership revoked while the member chooses it: never usable afterwards", c do
    owner = user!(c.users, "race-owner")

    for _ <- 1..@rounds do
      %{organization: org} = provision!(owner)
      member = user!(c.users, "race-member")
      membership = member!(org, member)

      [chose, {:ok, _}] =
        concurrently([
          fn -> choose(member, org.id) end,
          fn -> Provisioning.revoke_membership(fixture_authority(), membership.id, "left") end
        ])

      assert chose in [:ok, {:error, :not_found}]
      # A refused choice wrote nothing; an accepted one committed before the revocation.
      if chose == {:error, :not_found}, do: assert(choice_for(member) == nil)

      assert {:error, :not_found} = Sponsors.get_organization(member, org.id)
      refute sponsor_home?(member, org.id)
      assert {:ok, %{capabilities: []}} = Entry.resolve(member, %{})
      assert {:error, :not_found} = choose(member, org.id)
    end
  end

  test "organization suspended while members choose and resolve it", c do
    for _ <- 1..@rounds do
      owner = user!(c.users, "race-suspend-owner")
      %{organization: org} = provision!(owner)

      results =
        concurrently([
          fn -> {:choose, choose(owner, org.id)} end,
          fn -> {:resolve, sponsor_home?(owner, org.id)} end,
          fn ->
            {:suspend,
             Provisioning.suspend_organization(fixture_authority(), org.id, "policy_concern")}
          end,
          fn -> {:resolve, sponsor_home?(owner, org.id)} end
        ])

      assert {:suspend, {:ok, _}} = List.keyfind(results, :suspend, 0)
      assert {:choose, chose} = List.keyfind(results, :choose, 0)
      assert chose in [:ok, {:error, :not_found}]

      # After the commit: no entry, no choice, no workspace; reads are read-only.
      refute sponsor_home?(owner, org.id)
      assert {:ok, %{capabilities: [], sponsor_workspaces: []}} = Entry.resolve(owner, %{})
      assert {:error, :not_found} = choose(owner, org.id)

      assert {:ok, %{organization: %{status: :suspended}}} =
               Sponsors.get_organization(owner, org.id)
    end
  end

  test "reinstatement racing a choice: refused before it, accepted after it, never in between",
       c do
    for _ <- 1..@rounds do
      owner = user!(c.users, "race-reinstate")
      %{organization: org} = provision!(owner)
      {:ok, _} = Provisioning.suspend_organization(fixture_authority(), org.id, "policy_concern")
      assert {:error, :not_found} = choose(owner, org.id)

      [chose, {:ok, _}] =
        concurrently([
          fn -> choose(owner, org.id) end,
          fn ->
            Provisioning.reinstate_organization(fixture_authority(), org.id, "concern_resolved")
          end
        ])

      assert chose in [:ok, {:error, :not_found}]
      if chose == :ok, do: assert(choice_for(owner) == org.id)
      assert :ok = choose(owner, org.id)
      assert sponsor_home?(owner, org.id)
    end
  end

  test "provisioning racing resolution: a home only for a committed membership", c do
    for _ <- 1..@rounds do
      owner = user!(c.users, "race-approve")

      [provisioned | seen] =
        concurrently([
          fn -> provision!(owner) end
          | for(_ <- 1..4, do: fn -> Entry.resolve(owner, %{"intent" => "sponsor"}) end)
        ])

      org_id = provisioned.organization.id

      for {:ok, entry} <- seen do
        # Before the commit: no workspace; after it: exactly that organization.
        assert {entry.destination, entry.sponsor_id} in [
                 {:sponsor_application, nil},
                 {:sponsor_home, org_id}
               ]
      end

      assert sponsor_home?(owner, org_id)
    end
  end

  test "two organizations chosen while one is revoked: the stale choice is never honoured", c do
    for _ <- 1..@rounds do
      a_owner = user!(c.users, "race-a")
      b_owner = user!(c.users, "race-b")
      user = user!(c.users, "race-both")
      %{organization: a} = provision!(a_owner)
      %{organization: b} = provision!(b_owner)
      _ = member!(a, user)
      membership_b = member!(b, user)

      _ =
        concurrently([
          fn -> choose(user, a.id) end,
          fn -> choose(user, b.id) end,
          fn -> Provisioning.revoke_membership(fixture_authority(), membership_b.id, "left") end
        ])

      # Whatever row won, only `a` can be a destination now.
      assert {:ok, %{destination: :sponsor_home, sponsor_id: id}} =
               Entry.resolve(user, %{"intent" => "sponsor"})

      assert id == a.id
      assert {:error, :not_found} = Sponsors.get_organization(user, b.id)
    end
  end

  test "logout racing requests: once revoked, the access token authenticates nothing", c do
    owner = user!(c.users, "race-logout")
    %{organization: org} = provision!(owner)

    for _ <- 1..@rounds do
      {:ok, credentials} = Accounts.create_session(owner)
      token = credentials.access_token

      results =
        concurrently([
          fn -> Accounts.revoke_session({:access, token}) end
          | for(_ <- 1..4, do: fn -> Accounts.authenticate_access_token(token) end)
        ])

      assert hd(results) == :ok

      for result <- tl(results) do
        assert match?({:ok, %{user: %{id: id}}} when id == owner.id, result) or
                 result == {:error, :unauthorized}
      end

      assert {:error, :unauthorized} = Accounts.authenticate_access_token(token)
      # The organization itself is untouched by a logout.
      assert {:ok, _} = Sponsors.get_organization(owner, org.id)
    end
  end
end
