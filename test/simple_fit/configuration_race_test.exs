defmodule SimpleFit.ConfigurationRaceTest do
  @moduledoc """
  SF-128 under true concurrency and real commits, on separate connections outside the
  SQL sandbox: two operators changing one flag from the same revision, a change racing
  its rollback, one confirmation used twice at once, one operation sent twice at once,
  and propagation: a consumer in another process sees the committed value on its next
  check, never an uncommitted one, and is never blocked by a change in progress. Each
  test empties the operator and flag-history tables with TRUNCATE (append-only for the
  application) on this disposable test database, resets the flags and deletes its users.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Configuration, Operators, Repo}
  alias SimpleFit.Configuration.{FlagRevision, RuntimeFlag}
  alias SimpleFit.Gyms.MemberInvitations

  @tables ~w(runtime_flag_revisions operator_action_confirmations operator_audit_events
             operator_operations operator_ceremonies operator_permission_grants
             operator_step_ups operator_webauthn_challenges operator_credentials
             platform_operators)
  @all ~w(config.read config.flags.write operators.read operators.manage)

  setup do
    Sandbox.mode(Repo, :auto)
    reset!()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      reset!()
      Repo.delete_all(from(u in User, where: u.id in ^Agent.get(users, & &1)))
      Repo.delete_all("auth_rate_limits")
      untrust_ceremony_keys!()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    founder = founder!(users)
    %{users: users, founder: founder, second: second!(founder, users)}
  end

  defp reset! do
    Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")
    Repo.query!("UPDATE runtime_flags SET suspended = false")
  end

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp founder!(users) do
    user = track(users, registered!("founder"))
    session = live_session!(user)
    _ = bootstrap!(user, @all)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, key: step_up!(user, session, k)}
  end

  defp second!(founder, users) do
    user = track(users, registered!("second"))
    session = live_session!(user)

    {:ok, _} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{
          "user_id" => user.id,
          "permissions" => ["config.read", "config.flags.write"]
        })
      )

    [k | _] = enroll!(user, session)
    %{user: user, session: session, key: step_up!(user, session, k)}
  end

  defp flag(key), do: Repo.get_by!(RuntimeFlag, key: key)

  defp confirmed!(o, action, flag, reason) do
    params = %{"reason_code" => reason, "expected_revision" => flag.revision}
    {:ok, preview} = Operators.preview(action, o.user, o.session, flag.id, params)

    Map.merge(params, %{
      "confirmation_token" => preview.confirmation.token,
      "operation_id" => Ecto.UUID.generate()
    })
  end

  defp run(o, action, flag, request),
    do: fn -> Operators.execute(action, o.user, o.session, flag.id, request) end

  defp concurrently(funs),
    do: funs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))

  defp revisions(flag_id),
    do: Repo.aggregate(from(r in FlagRevision, where: r.flag_id == ^flag_id), :count)

  test "two operators suspend one flag from the same revision: one commits, the other conflicts",
       c do
    f = flag("gym.member_invitations")
    a = confirmed!(c.founder, "config.flag.suspend", f, "incident_response")
    b = confirmed!(c.second, "config.flag.suspend", f, "abuse_or_spam")

    results =
      concurrently([
        run(c.founder, "config.flag.suspend", f, a),
        run(c.second, "config.flag.suspend", f, b)
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, fn
             {:error, {:revision_conflict, %{current_revision: revision}}} ->
               revision == f.revision + 1

             {:error, {:conflict, %{status: "suspended"}}} ->
               true

             _ ->
               false
           end) == 1

    assert %RuntimeFlag{suspended: true} = changed = flag("gym.member_invitations")
    assert changed.revision == f.revision + 1
    assert revisions(f.id) == 1
  end

  test "a change racing its rollback: never both, and history matches the final state", c do
    f = flag("sponsor.application_emails")

    {:ok, _} =
      run(
        c.founder,
        "config.flag.suspend",
        f,
        confirmed!(c.founder, "config.flag.suspend", f, "release_issue")
      ).()

    suspended = flag("sponsor.application_emails")

    restore_a = confirmed!(c.founder, "config.flag.restore", suspended, "release_fixed")
    restore_b = confirmed!(c.second, "config.flag.restore", suspended, "suspended_in_error")

    results =
      concurrently([
        run(c.founder, "config.flag.restore", suspended, restore_a),
        run(c.second, "config.flag.restore", suspended, restore_b)
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    final = flag("sponsor.application_emails")
    assert %RuntimeFlag{suspended: false} = final
    assert final.revision == f.revision + 2

    history = Repo.all(from(r in FlagRevision, where: r.flag_id == ^f.id, order_by: r.revision))

    assert Enum.map(history, &{&1.revision, &1.change}) ==
             [{f.revision + 1, :suspend}, {f.revision + 2, :restore}]
  end

  test "one confirmation used twice at once: one change", c do
    f = flag("sponsor.evidence_uploads")
    request = confirmed!(c.founder, "config.flag.suspend", f, "provider_outage")
    other = Map.put(request, "operation_id", Ecto.UUID.generate())

    results =
      concurrently([
        run(c.founder, "config.flag.suspend", f, request),
        run(c.founder, "config.flag.suspend", f, other)
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert revisions(f.id) == 1
  end

  test "one operation sent twice at once: one change, both answered", c do
    f = flag("gym.staff_invitations")
    request = confirmed!(c.founder, "config.flag.suspend", f, "planned_maintenance")

    results =
      concurrently([
        run(c.founder, "config.flag.suspend", f, request),
        run(c.founder, "config.flag.suspend", f, request)
      ])

    assert Enum.all?(results, &match?({:ok, %{suspended: true}}, &1))
    assert revisions(f.id) == 1
    assert flag("gym.staff_invitations").revision == f.revision + 1
  end

  test "propagation: other processes see the committed value on their next check, never an uncommitted one",
       _c do
    f = flag("gym.member_invitations")
    test = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          locked = Configuration.lock_flag!(f.id)
          operator_id = Repo.one!(from(o in Operators.Operator, select: o.id, limit: 1))

          Configuration.set_suspended!(
            locked,
            true,
            operator_id,
            "incident_response",
            Ecto.UUID.generate()
          )

          send(test, :uncommitted)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :uncommitted, 5_000

    # Another instance's consumer: not blocked by the lock, and still the committed value.
    {micros, during} =
      :timer.tc(fn -> Task.await(Task.async(&MemberInvitations.delivery_enabled?/0)) end)

    assert during
    assert micros < 2_000_000

    send(holder.pid, :commit)
    assert {:ok, :ok} = Task.await(holder, 15_000)

    # Committed: every process's next check sees it, with no cache to expire.
    checks = concurrently(for _ <- 1..8, do: &MemberInvitations.delivery_enabled?/0)
    assert Enum.all?(checks, &(&1 == false))
  end
end
