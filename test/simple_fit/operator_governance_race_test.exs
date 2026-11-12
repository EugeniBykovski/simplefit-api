defmodule SimpleFit.OperatorGovernanceRaceTest do
  @moduledoc """
  SF-129's governance invariants under true concurrency and real commits, on separate
  connections outside the SQL sandbox: the last holder of `operators.manage` survives two
  managers removing each other's permission or suspending each other at once (the
  action pipeline locks actor and target in id order and asks the actor's permission
  again under the locks), and provisioning the same account by email twice at once
  creates one operator. The operator tables are append-only for the application, so each test
  empties them with TRUNCATE (which those triggers don't cover) on this disposable
  test database, and deletes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Operators, Repo}
  alias SimpleFit.Operators.{Grant, Operator}

  @tables ~w(operator_action_confirmations operator_audit_events operator_operations operator_ceremonies operator_permission_grants
             operator_step_ups operator_webauthn_challenges operator_credentials platform_operators)

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      truncate!()
      ids = Agent.get(users, & &1)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all("auth_rate_limits")
      untrust_ceremony_keys!()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  # CASCADE: sponsor application change requests (SF-114) reference operators.
  defp truncate!, do: Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")

  defp user!(users, prefix) do
    user = registered!(prefix)
    Agent.update(users, &[user.id | &1])
    user
  end

  defp concurrently(funs),
    do: funs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))

  defp founder!(users) do
    user = user!(users, "founder")
    session = live_session!(user)
    op = bootstrap!(user)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

  defp manager!(founder, users) do
    user = user!(users, "manager")
    session = live_session!(user)

    {:ok, %{operator: op}} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => ["operators.manage"]})
      )

    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

  defp managers do
    Repo.aggregate(
      from(o in Operator,
        join: g in Grant,
        on: g.operator_id == o.id and g.permission == "operators.manage" and is_nil(g.revoked_at),
        where: o.status == :active
      ),
      :count
    )
  end

  test "the last two managers removing each other's manage permission: one wins, one manager stays",
       %{users: users} do
    f = founder!(users)
    b = manager!(f, users)
    assert managers() == 2

    {:ok, f_removes_b, _} =
      confirmed(f.user, f.session, "operator.permission.revoke", b.operator.id, %{
        "permission" => "operators.manage"
      })

    {:ok, b_removes_f, _} =
      confirmed(b.user, b.session, "operator.permission.revoke", f.operator.id, %{
        "permission" => "operators.manage"
      })

    results =
      concurrently([
        fn ->
          Operators.execute(
            "operator.permission.revoke",
            f.user,
            f.session,
            b.operator.id,
            f_removes_b
          )
        end,
        fn ->
          Operators.execute(
            "operator.permission.revoke",
            b.user,
            b.session,
            f.operator.id,
            b_removes_f
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :forbidden}, &1)) == 1
    assert managers() == 1
  end

  test "the last two managers suspending each other: one wins, one manager stays", %{users: users} do
    f = founder!(users)
    b = manager!(f, users)

    {:ok, f_suspends_b, _} = confirmed(f.user, f.session, "operator.suspend", b.operator.id)
    {:ok, b_suspends_f, _} = confirmed(b.user, b.session, "operator.suspend", f.operator.id)

    results =
      concurrently([
        fn -> Operators.suspend(f.user, f.session, b.operator.id, f_suspends_b) end,
        fn -> Operators.suspend(b.user, b.session, f.operator.id, b_suspends_f) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert managers() == 1
    assert Repo.aggregate(from(o in Operator, where: o.status == :suspended), :count) == 1
  end

  test "the same account provisioned by email twice at once: one operator", %{users: users} do
    f = founder!(users)
    email = "race-#{System.unique_integer([:positive])}@example.com"
    {:ok, target} = SimpleFit.Accounts.register_user(:email, email)
    Agent.update(users, &[target.id | &1])

    {:ok, _} =
      SimpleFit.Accounts.update_account_registration(target, %{
        "full_name" => "Jan Race",
        "date_of_birth" => "1990-04-12",
        "accept_terms" => true,
        "accept_privacy" => true
      })

    {:ok, _} = SimpleFit.Accounts.complete_account_registration(target)

    results =
      concurrently(
        for _ <- 1..4 do
          fn ->
            Operators.provision(
              f.user,
              f.session,
              Map.merge(op(), %{"email" => email, "permissions" => ["audit.read"]})
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results -- Enum.filter(results, &match?({:ok, _}, &1)),
             &match?({:error, {:conflict, %{operator: "exists"}}}, &1)
           )

    assert Repo.aggregate(from(o in Operator, where: o.user_id == ^target.id), :count) == 1
  end
end
