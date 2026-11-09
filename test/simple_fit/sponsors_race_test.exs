defmodule SimpleFit.SponsorsRaceTest do
  @moduledoc """
  SF-112 under true concurrency and real commits, on separate connections outside
  the SQL sandbox: unique indexes, row locks, transition triggers and the deferred
  one-owner check run for real. Sponsor tables are never deleted from by the
  application, so each test empties them with TRUNCATE on this disposable test
  database and deletes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Entry, Repo}
  alias SimpleFit.Sponsors.{Membership, Organization, OrganizationEvent, Provisioning}

  @tables ~w(sponsor_organization_events sponsor_contacts sponsor_workspace_memberships sponsor_organizations)

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)

      Repo.delete_all(
        from(c in "entry_context_choices", where: c.user_id in type(^ids, {:array, :binary_id}))
      )

      truncate!()
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all("auth_rate_limits")
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  defp truncate!, do: Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")

  defp user!(users, prefix) do
    user = registered!(prefix)
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs),
    do: funs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))

  test "the same provisioning, six times at once, makes one organization", %{users: users} do
    owner = user!(users, "owner")
    attrs = org_attrs(owner)

    results =
      concurrently(
        for _ <- 1..6,
            do: fn -> Provisioning.provision_organization(fixture_authority(), attrs) end
      )

    ids = for {:ok, %{organization: o}} <- results, uniq: true, do: o.id
    assert length(ids) == 1 and length(results) == 6
    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Repo.aggregate(Organization, :count) == 1
    assert Repo.aggregate(Membership, :count) == 1
  end

  test "the same user added five times at once has one membership", %{users: users} do
    %{organization: org} = provision!(user!(users, "owner"))
    user = user!(users, "member")

    results =
      concurrently(
        for _ <- 1..5,
            do: fn -> Provisioning.add_member(fixture_authority(), org.id, user.id, :member) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results,
             &(match?({:ok, _}, &1) or &1 == {:error, {:conflict, %{membership: "exists"}}})
           )

    assert Repo.aggregate(
             from(m in Membership, where: m.organization_id == ^org.id and m.user_id == ^user.id),
             :count
           ) == 1
  end

  test "a context choice racing the membership's revocation never outlives it", %{users: users} do
    %{organization: org} = provision!(user!(users, "owner"))
    user = user!(users, "member")
    m = member!(org, user)

    [choice, revoke] =
      concurrently([
        fn ->
          Entry.record_context_choice(user, %{"context" => "sponsor", "sponsor_id" => org.id})
        end,
        fn -> Provisioning.revoke_membership(fixture_authority(), m.id, "left_company") end
      ])

    assert {:ok, _} = revoke
    assert match?({:ok, _}, choice) or choice == {:error, :not_found}

    assert {:ok, %{destination: :sponsor_application, sponsor_id: nil}} =
             Entry.resolve(user, %{"intent" => "sponsor"})

    assert {:ok, %{sponsor_workspace_count: 0}} = Entry.resolve(user)
  end

  test "suspension racing revocation of one membership: legal states and one event each", %{
    users: users
  } do
    %{organization: org} = provision!(user!(users, "owner"))
    m = member!(org, user!(users, "member"))

    results =
      concurrently([
        fn -> Provisioning.suspend_membership(fixture_authority(), m.id, "security_review") end,
        fn -> Provisioning.revoke_membership(fixture_authority(), m.id, "left_company") end
      ])

    # Revocation is legal from active and from suspended, so it always lands last.
    assert [_suspend, {:ok, %{status: :revoked}}] = results
    assert Repo.get!(Membership, m.id).status == :revoked
    successes = Enum.count(results, &match?({:ok, _}, &1))

    assert Repo.aggregate(
             from(e in OrganizationEvent,
               where:
                 e.membership_id == ^m.id and
                   e.event in ["membership.suspended", "membership.revoked"]
             ),
             :count
           ) == successes
  end

  test "closing an organization racing a new member never leaves an active member behind", %{
    users: users
  } do
    %{organization: org} = provision!(user!(users, "owner"))
    user = user!(users, "late")

    [add, close] =
      concurrently([
        fn -> Provisioning.add_member(fixture_authority(), org.id, user.id, :member) end,
        fn -> Provisioning.close_organization(fixture_authority(), org.id, "business_closed") end
      ])

    assert {:ok, %{status: :closed}} = close
    assert match?({:ok, _}, add) or add == {:error, {:conflict, %{status: "closed"}}}

    assert Repo.aggregate(
             from(m in Membership, where: m.organization_id == ^org.id and m.status != :revoked),
             :count
           ) == 0
  end
end
