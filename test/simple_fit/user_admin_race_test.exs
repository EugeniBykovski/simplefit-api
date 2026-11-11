defmodule SimpleFit.UserAdminRaceTest do
  @moduledoc """
  SF-122 under true concurrency and real commits, on separate connections outside the
  SQL sandbox: suspension and sign-out against sign-in and refresh at their commit
  boundary (deterministic: the competing request is observed blocked on the row lock
  in `pg_stat_activity` before the first transaction commits), two operators acting on
  one account at once, a duplicated operation, provisioning an operator while its
  user is being suspended, and an audit failure rolling the whole action back. Each
  test empties the operator tables with TRUNCATE (append-only for the application) on
  this disposable test database and deletes the users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.{Accounts, Operators, Repo}
  alias SimpleFit.Accounts.{Restriction, Session, User}
  alias SimpleFit.Operators.AuditEvent

  @tables ~w(user_restrictions user_account_states operator_action_confirmations
             operator_audit_events operator_operations operator_ceremonies
             operator_permission_grants operator_step_ups operator_webauthn_challenges
             operator_credentials platform_operators)
  @all ~w(users.read users.restrict users.sessions.revoke operators.read operators.manage)

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.query!("ALTER TABLE operator_audit_events DROP CONSTRAINT IF EXISTS sf122_audit_fails")
      truncate!()
      Repo.delete_all(from(u in User, where: u.id in ^Agent.get(users, & &1)))
      Repo.delete_all("auth_rate_limits")
      untrust_ceremony_keys!()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users, founder: founder!(users)}
  end

  defp truncate!, do: Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp founder!(users) do
    user = track(users, registered!("founder"))
    session = live_session!(user)
    op = bootstrap!(user, @all)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

  defp second!(founder, users) do
    user = track(users, registered!("second"))
    session = live_session!(user)

    {:ok, _} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => ["users.read", "users.restrict"]})
      )

    [k | _] = enroll!(user, session)
    %{user: user, session: session, key: step_up!(user, session, k)}
  end

  defp prepared(o, action, target_id) do
    {:ok, execute, _preview} = confirmed(o.user, o.session, action, target_id)
    fn -> Operators.execute(action, o.user, o.session, target_id, execute) end
  end

  defp concurrently(funs),
    do: funs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))

  defp active_sessions(user_id),
    do:
      Repo.aggregate(
        from(s in Session, where: s.user_id == ^user_id and is_nil(s.revoked_at)),
        :count
      )

  # Waits (bounded) until some backend is waiting on a row lock: the competing request
  # reached the lock the open transaction holds.
  defp await_lock_wait(tries \\ 200) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()"
      )

    cond do
      waiting > 0 -> :ok
      tries == 0 -> flunk("the competing request never waited on the lock")
      true -> Process.sleep(10) && await_lock_wait(tries - 1)
    end
  end

  # Runs `work` inside a transaction that stays open until the test says `:commit`.
  defp hold_open(work) do
    test = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        result = work.()
        send(test, :holding)

        receive do
          :commit -> result
        end
      end)
    end)
  end

  test "A: a sign-in that reaches the lock while a suspension is uncommitted is refused after it commits",
       c do
    target = track(c.users, registered!("target"))
    operator_id = c.founder.operator.id

    suspension =
      hold_open(fn ->
        Accounts.lock_account!(target.id)
        Accounts.suspend_account!(target.id, operator_id, "fraud", DateTime.utc_now())
      end)

    assert_receive :holding, 5_000
    sign_in = Task.async(fn -> Accounts.create_session(target) end)
    await_lock_wait()
    send(suspension.pid, :commit)

    assert {:ok, _} = Task.await(suspension, 15_000)
    assert {:error, :account_suspended} = Task.await(sign_in, 15_000)
    assert active_sessions(target.id) == 0
  end

  test "B: a sign-in committed before the suspension is revoked by it", c do
    target = track(c.users, registered!("target"))
    {:ok, early} = Accounts.create_session(target)

    assert {:ok, _} = prepared(c.founder, "user.suspend", target.id).()
    assert active_sessions(target.id) == 0
    assert {:error, :unauthorized} = Accounts.refresh_session(early.refresh_token)
    assert {:error, :unauthorized} = Accounts.authenticate_access_token(early.access_token)
  end

  test "C: a refresh waiting on an uncommitted sign-out is refused after it commits", c do
    target = track(c.users, registered!("target"))
    {:ok, creds} = Accounts.create_session(target)

    sign_out =
      hold_open(fn ->
        Accounts.lock_account!(target.id)
        Accounts.sign_out_everywhere!(target.id, DateTime.utc_now())
      end)

    assert_receive :holding, 5_000
    refresh = Task.async(fn -> Accounts.refresh_session(creds.refresh_token) end)
    await_lock_wait()
    send(sign_out.pid, :commit)

    assert {:ok, 1} = Task.await(sign_out, 15_000)
    assert {:error, :unauthorized} = Task.await(refresh, 15_000)
    assert active_sessions(target.id) == 0
  end

  test "D: two operators suspend one account at once: one suspension, one audit, one loser", c do
    other = second!(c.founder, c.users)
    target = track(c.users, registered!("target"))

    results =
      concurrently([
        prepared(c.founder, "user.suspend", target.id),
        prepared(other, "user.suspend", target.id)
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.any?(results, &match?({:error, {:revision_conflict, _}}, &1))
    assert Repo.aggregate(Restriction, :count) == 1

    assert Repo.aggregate(
             from(e in AuditEvent, where: e.action == "user.suspended" and e.outcome == :allowed),
             :count
           ) == 1
  end

  test "E: lift and sign-out at the same revision: exactly one applies", c do
    other = second!(c.founder, c.users)
    target = track(c.users, registered!("target"))
    {:ok, _} = prepared(c.founder, "user.suspend", target.id).()

    results =
      concurrently([
        prepared(c.founder, "user.lift_suspension", target.id),
        prepared(%{other | user: other.user}, "user.lift_suspension", target.id)
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert [%{lifted_at: %DateTime{}}] = Repo.all(Restriction)
    assert Accounts.account_state(target.id).status == :active
  end

  test "F: the same operation sent twice at once changes the account once", c do
    target = track(c.users, registered!("target"))
    {:ok, execute, _} = confirmed(c.founder.user, c.founder.session, "user.suspend", target.id)

    run = fn ->
      Operators.execute("user.suspend", c.founder.user, c.founder.session, target.id, execute)
    end

    results = concurrently([run, run])

    assert Enum.all?(results, &match?({:ok, %{status: "suspended"}}, &1)) or
             Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Repo.aggregate(Restriction, :count) == 1
    assert Accounts.account_state(target.id).revision == 2
  end

  test "G: provisioning an operator for a user being suspended never yields a suspended usable operator",
       c do
    target = track(c.users, registered!("target"))
    suspend = prepared(c.founder, "user.suspend", target.id)

    provision = fn ->
      Operators.provision(
        c.founder.user,
        c.founder.session,
        Map.merge(op(), %{"user_id" => target.id, "permissions" => ["users.read"]})
      )
    end

    [suspended, provisioned] = concurrently([suspend, provision])

    case {suspended, provisioned} do
      # The suspension first: the new operator is only pending enrolment, on an account
      # that can't sign in to enrol; nothing an operator had is taken away.
      {{:ok, _}, {:ok, %{operator: op}}} -> assert op.status == :pending_enrollment
      # The operator first: the suspension sees a platform operator and is refused.
      {{:error, {:conflict, %{target: "operator"}}}, {:ok, _}} -> :ok
      other -> flunk("unexpected outcome #{inspect(other)}")
    end
  end

  test "H: when the audit event can't be written, the suspension doesn't commit", c do
    target = track(c.users, registered!("target"))
    {:ok, creds} = Accounts.create_session(target)

    Repo.query!("""
    ALTER TABLE operator_audit_events ADD CONSTRAINT sf122_audit_fails
      CHECK (action <> 'user.suspended') NOT VALID
    """)

    {:ok, execute, _} = confirmed(c.founder.user, c.founder.session, "user.suspend", target.id)

    run = fn ->
      Operators.execute("user.suspend", c.founder.user, c.founder.session, target.id, execute)
    end

    assert {:error, _} = run.()
    assert Repo.aggregate(Restriction, :count) == 0
    assert Accounts.account_state(target.id).status == :active
    assert {:ok, _} = Accounts.authenticate_access_token(creds.access_token)

    Repo.query!("ALTER TABLE operator_audit_events DROP CONSTRAINT sf122_audit_fails")
    assert {:ok, %{status: "suspended"}} = run.()
    assert Repo.aggregate(Restriction, :count) == 1
  end
end
