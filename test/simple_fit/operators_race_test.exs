defmodule SimpleFit.OperatorsRaceTest do
  @moduledoc """
  SF-110 under true concurrency and real commits, on separate connections outside
  the SQL sandbox: the advisory lock, row locks, unique indexes and triggers run for
  real. The operator tables are append-only for the application, so each test
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
  alias SimpleFit.Operators.{AuditEvent, Bootstrap, Confirmation, Grant, Operation, Operator}
  alias SimpleFit.Operators.StepUp

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

  test "concurrent bootstraps for different users create exactly one founder", %{users: users} do
    private = trust_ceremony_key!()
    statements = for i <- 1..6, do: statement(private, user!(users, "candidate-#{i}"))
    results = concurrently(Enum.map(statements, fn s -> fn -> Bootstrap.run(s) end end))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results -- Enum.filter(results, &match?({:ok, _}, &1)),
             &(&1 == {:error, :operator_exists})
           )

    assert Repo.aggregate(Operator, :count) == 1
  end

  test "the same statement replayed concurrently is consumed once", %{users: users} do
    private = trust_ceremony_key!()
    signed = statement(private, user!(users, "founder"))
    results = concurrently(for _ <- 1..6, do: fn -> Bootstrap.run(signed) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results,
             &(match?({:ok, _}, &1) or &1 in [{:error, :replayed}, {:error, :operator_exists}])
           )
  end

  test "an assertion submitted concurrently records one key check", %{users: users} do
    f = founder!(users)
    {:ok, options} = Operators.step_up_options(f.user, f.session)
    {response, _} = assertion_response(f.key, options)

    results =
      concurrently(
        for _ <- 1..6, do: fn -> Operators.verify_step_up(f.user, f.session, response) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 == {:error, :security_key_rejected}))
  end

  test "two managers revoking each other: at most one succeeds", %{users: users} do
    f = founder!(users)
    a = manager!(f, users)
    b = manager!(f, users)

    {:ok, a_revokes_b, _} = confirmed(a.user, a.session, "operator.revoke", b.operator.id)
    {:ok, b_revokes_a, _} = confirmed(b.user, b.session, "operator.revoke", a.operator.id)

    results =
      concurrently([
        fn -> Operators.revoke(a.user, a.session, b.operator.id, a_revokes_b) end,
        fn -> Operators.revoke(b.user, b.session, a.operator.id, b_revokes_a) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.member?(results, {:error, :not_found})
    assert Repo.aggregate(from(o in Operator, where: o.status == :revoked), :count) == 1
  end

  test "concurrent grants of the same permission leave one active grant", %{users: users} do
    f = founder!(users)
    a = manager!(f, users)
    target = Repo.get!(Operator, a.operator.id)

    # Five confirmed grants of the same revision: one commits, the rest are stale.
    payloads =
      for _ <- 1..5 do
        {:ok, payload, _} =
          confirmed(f.user, f.session, "operator.permission.grant", target.id, %{
            "permission" => "audit.read"
          })

        payload
      end

    results =
      concurrently(
        for payload <- payloads,
            do: fn -> Operators.grant(f.user, f.session, target.id, payload) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results,
             &(match?({:ok, _}, &1) or match?({:error, {:revision_conflict, _}}, &1))
           )

    assert Repo.aggregate(
             from(g in Grant,
               where:
                 g.operator_id == ^target.id and g.permission == "audit.read" and
                   is_nil(g.revoked_at)
             ),
             :count
           ) == 1
  end

  test "a grant racing the granter's revocation never commits after it", %{users: users} do
    f = founder!(users)
    granter = manager!(f, users)
    target_user = user!(users, "target")

    {:ok, %{operator: target}} =
      Operators.provision(
        f.user,
        f.session,
        Map.merge(op(), %{"user_id" => target_user.id, "permissions" => ["operators.read"]})
      )

    {:ok, grant, _} =
      confirmed(granter.user, granter.session, "operator.permission.grant", target.id, %{
        "permission" => "audit.read"
      })

    {:ok, revoke, _} = confirmed(f.user, f.session, "operator.revoke", granter.operator.id)

    [grant_result, revoke_result] =
      concurrently([
        fn -> Operators.grant(granter.user, granter.session, target.id, grant) end,
        fn -> Operators.revoke(f.user, f.session, granter.operator.id, revoke) end
      ])

    assert {:ok, _} = revoke_result
    revoked_at = Repo.get!(Operator, granter.operator.id).revoked_at

    case grant_result do
      {:ok, _} ->
        grant =
          Repo.one!(
            from(g in Grant, where: g.operator_id == ^target.id and g.permission == "audit.read")
          )

        assert DateTime.compare(grant.granted_at, revoked_at) == :lt

      {:error, reason} ->
        assert reason == :not_found
    end
  end

  test "a key check racing the operator's suspension never survives it", %{users: users} do
    f = founder!(users)
    a = manager!(f, users)
    {:ok, options} = Operators.step_up_options(a.user, a.session)
    {response, _} = assertion_response(a.key, options)
    {:ok, suspend, _} = confirmed(f.user, f.session, "operator.suspend", a.operator.id)

    concurrently([
      fn -> Operators.verify_step_up(a.user, a.session, response) end,
      fn -> Operators.suspend(f.user, f.session, a.operator.id, suspend) end
    ])

    assert Repo.get!(Operator, a.operator.id).status == :suspended

    assert Repo.aggregate(
             from(s in StepUp, where: s.operator_id == ^a.operator.id and is_nil(s.revoked_at)),
             :count
           ) == 0

    assert {:error, :not_found} = Operators.list_operators(a.user, a.session)
  end

  ## SF-111 admin actions

  test "one confirmation raced with different operation ids commits once", %{users: users} do
    f = founder!(users)
    a = manager!(f, users)
    {:ok, payload, _} = confirmed(f.user, f.session, "operator.suspend", a.operator.id)

    results =
      concurrently(
        for _ <- 1..5,
            do: fn ->
              Operators.suspend(f.user, f.session, a.operator.id, %{
                payload
                | "operation_id" => Ecto.UUID.generate()
              })
            end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results,
             &(match?({:ok, _}, &1) or match?({:error, {:revision_conflict, _}}, &1) or
                 &1 == {:error, :confirmation_invalid})
           )

    assert Repo.aggregate(from(x in Confirmation, where: not is_nil(x.consumed_at)), :count) == 1
    assert allowed("operator.suspend") == 1
  end

  test "an ambiguous retry, sent five times at once, has one effect", %{users: users} do
    f = founder!(users)
    a = manager!(f, users)
    {:ok, payload, _} = confirmed(f.user, f.session, "operator.revoke", a.operator.id)

    results =
      concurrently(
        for _ <- 1..5, do: fn -> Operators.revoke(f.user, f.session, a.operator.id, payload) end
      )

    assert Enum.all?(results, &match?({:ok, %{operator: %{status: :revoked}}}, &1))
    assert allowed("operator.revoke") == 1

    assert Repo.aggregate(from(o in Operation, where: o.id == ^payload["operation_id"]), :count) ==
             1
  end

  test "two managers' conflicting actions on one target: one wins, one is stale", %{users: users} do
    f = founder!(users)
    a = manager!(f, users)
    b = manager!(f, users)
    target = manager!(f, users)
    {:ok, suspend, _} = confirmed(a.user, a.session, "operator.suspend", target.operator.id)
    {:ok, revoke, _} = confirmed(b.user, b.session, "operator.revoke", target.operator.id)

    results =
      concurrently([
        fn -> Operators.suspend(a.user, a.session, target.operator.id, suspend) end,
        fn -> Operators.revoke(b.user, b.session, target.operator.id, revoke) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:revision_conflict, _}}, &1)) == 1
    assert allowed("operator.suspend") + allowed("operator.revoke") == 1
  end

  defp allowed(command),
    do:
      Repo.aggregate(
        from(e in AuditEvent, where: e.command == ^command and e.outcome == :allowed),
        :count
      )
end
