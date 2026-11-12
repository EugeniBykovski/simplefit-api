defmodule SimpleFit.SponsorPartnershipsRaceTest do
  @moduledoc """
  SF-130 under true concurrency and real commits, on separate connections outside
  the SQL sandbox (each call runs in its own `Task`, so its own pooled connection and
  transaction): idempotent creates and submissions, the open proposal limit, revision
  races, a withdrawal racing an operator's claim, two operators deciding at once, a
  membership revoked while a member submits, and two first saves of preferences. The
  tables are append-only for the application, so each test empties them with
  TRUNCATE on this disposable test database and deletes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.OperatorHelpers, only: [untrust_ceremony_keys!: 0]
  import SimpleFit.PartnershipHelpers
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.Repo

  alias SimpleFit.Sponsors.{
    Membership,
    PartnershipPreferences,
    Partnerships,
    Proposal,
    ProposalSubmission,
    Provisioning
  }

  @tables ~w(sponsor_partnership_events sponsor_partnership_change_requests
             sponsor_partnership_proposal_submissions sponsor_partnership_proposals
             sponsor_partnership_preferences sponsor_organization_events sponsor_contacts
             sponsor_workspace_memberships sponsor_organizations
             operator_action_confirmations operator_audit_events operator_operations
             operator_ceremonies operator_permission_grants operator_step_ups
             operator_webauthn_challenges operator_credentials platform_operators)

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      truncate!()
      Repo.delete_all(from(u in User, where: u.id in ^Agent.get(users, & &1)))
      Repo.delete_all("auth_rate_limits")
      untrust_ceremony_keys!()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    owner = track(users, registered!("owner"))
    manager = track(users, registered!("manager"))
    %{organization: org} = provision!(owner)
    manager_membership = member!(org, manager, :manager)
    %{users: users, owner: owner, manager: manager, mm: manager_membership, org: org}
  end

  defp truncate!, do: Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs),
    do: funs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))

  defp ok_count(results), do: Enum.count(results, &match?({:ok, _}, &1))

  test "the same create ten times at once makes one draft", c do
    params = Map.put(proposal_answers(), "client_request_id", Ecto.UUID.generate())

    results =
      concurrently(
        for user <- List.duplicate(c.owner, 5) ++ List.duplicate(c.manager, 5),
            do: fn -> Partnerships.create_proposal(user, c.org.id, params) end
      )

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert results |> Enum.map(fn {:ok, v} -> v.proposal.id end) |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(Proposal, :count) == 1
  end

  test "concurrent creates never pass the open proposal limit", c do
    for _ <- 1..23, do: draft_proposal!(c.owner, c.org)

    results =
      concurrently(
        for _ <- 1..8 do
          fn ->
            Partnerships.create_proposal(
              c.manager,
              c.org.id,
              Map.put(proposal_answers(), "client_request_id", Ecto.UUID.generate())
            )
          end
        end
      )

    assert ok_count(results) == 2

    assert Enum.count(results, &match?({:error, {:conflict, %{proposals: "open_limit"}}}, &1)) ==
             6

    assert Repo.aggregate(Proposal, :count) == 25
  end

  test "submissions racing on one revision make exactly one snapshot", c do
    p = draft_proposal!(c.owner, c.org)
    same = command(p)

    results =
      concurrently(
        for i <- 1..10 do
          fn ->
            params = if rem(i, 2) == 0, do: same, else: command(p)
            Partnerships.submit_proposal(c.owner, c.org.id, p.id, params)
          end
        end
      )

    assert Repo.aggregate(ProposalSubmission, :count) == 1
    assert Repo.reload!(p).status == :submitted

    for result <- results do
      assert match?({:ok, %{proposal: %{status: :submitted}}}, result) or
               match?({:error, {:revision_conflict, _}}, result) or
               match?({:error, {:conflict, _}}, result)
    end

    # Every repeat of the request that won answers as it did.
    [%{client_request_id: key}] = Repo.all(ProposalSubmission)

    if key == same["client_request_id"],
      do: assert(Enum.count(results, &match?({:ok, _}, &1)) == 5)
  end

  test "edits racing on one revision: one wins, the others are stale", c do
    p = draft_proposal!(c.owner, c.org)

    results =
      concurrently(
        for i <- 1..8 do
          fn ->
            Partnerships.update_proposal(c.manager, c.org.id, p.id, %{
              "expected_revision" => 1,
              "title" => "Title #{i}"
            })
          end
        end
      )

    assert ok_count(results) == 1
    assert Enum.count(results, &match?({:error, {:revision_conflict, _}}, &1)) == 7
    assert Repo.reload!(p).revision == 2
  end

  test "a withdrawal racing an operator's claim: exactly one happens", c do
    r = founder!(review_permissions())
    track(c.users, r.user)

    for _ <- 1..5 do
      p = submitted_proposal!(c.owner, c.org, draft_proposal!(c.owner, c.org))
      withdraw = command(p)

      [claimed, withdrawn] =
        concurrently([
          fn -> claim(r, p) end,
          fn -> Partnerships.withdraw_proposal(c.owner, c.org.id, p.id, withdraw) end
        ])

      final = Repo.reload!(p).status

      case final do
        :under_review ->
          assert {:ok, _} = claimed
          assert {:error, {:revision_conflict, _}} = withdrawn

        :withdrawn ->
          assert {:ok, _} = withdrawn
          assert {:error, _} = claimed
      end
    end
  end

  test "two operators deciding at once: one decision", c do
    founder = founder!(review_permissions() ++ ~w(operators.read operators.manage))
    track(c.users, founder.user)
    second = operator_for!(founder, track(c.users, registered!("second")), review_permissions())
    p = submitted_proposal!(c.owner, c.org, draft_proposal!(c.owner, c.org))
    {:ok, _} = claim(founder, p)

    results =
      concurrently([
        fn -> decide(founder, "sponsor_proposal.accept", p, "follow_up_planned") end,
        fn -> decide(second, "sponsor_proposal.decline", p, "not_a_fit_now") end
      ])

    assert ok_count(results) == 1
    assert Repo.reload!(p).status in [:accepted, :declined]
  end

  test "a membership revoked while its member submits: the submit is before or refused", c do
    for _ <- 1..5 do
      manager = track(c.users, registered!("racer"))
      membership = member!(c.org, manager, :manager)
      p = draft_proposal!(c.owner, c.org)

      [submitted, revoked] =
        concurrently([
          fn -> Partnerships.submit_proposal(manager, c.org.id, p.id, command(p)) end,
          fn ->
            Provisioning.revoke_membership(fixture_authority(), membership.id, "left_company")
          end
        ])

      assert {:ok, %Membership{status: :revoked, revoked_at: revoked_at}} = revoked

      case submitted do
        {:ok, _} ->
          [submission] = Repo.all(from(s in ProposalSubmission, where: s.proposal_id == ^p.id))
          assert DateTime.compare(submission.submitted_at, revoked_at) != :gt

        {:error, :not_found} ->
          assert Repo.reload!(p).status == :draft
      end

      assert {:error, :not_found} = Partnerships.get_proposal(manager, c.org.id, p.id)
    end
  end

  test "two first saves of preferences make one row", c do
    results =
      concurrently(
        for user <- [c.owner, c.manager, c.owner, c.manager] do
          fn ->
            Partnerships.save_preferences(user, c.org.id, %{
              "expected_revision" => 0,
              "interests" => ["content"]
            })
          end
        end
      )

    assert ok_count(results) == 1
    assert Enum.count(results, &match?({:error, {:revision_conflict, _}}, &1)) == 3
    assert [%PartnershipPreferences{revision: 1}] = Repo.all(PartnershipPreferences)
  end
end
