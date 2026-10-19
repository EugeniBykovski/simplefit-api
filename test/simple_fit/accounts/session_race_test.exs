defmodule SimpleFit.Accounts.SessionRaceTest do
  @moduledoc """
  Refresh rotation under real concurrency, on separate database connections
  (outside the SQL sandbox), as on several Phoenix nodes. A gate transaction
  holds the session row locked while the racers start; every refresh,
  recovery and logout of a session decides under that lock, so they all
  block and truly overlap. Releasing the gate lets them race: exactly one
  live token survives, a stale token is reuse, and the lost-response recovery
  (SF-75) never produces a second chain. Rows are committed for real and
  removed afterwards.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{RefreshToken, Session, Sessions, User}
  alias SimpleFit.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    marker = "session-race-#{System.unique_integer([:positive])}"
    {:ok, user} = Accounts.register_user(:google, marker)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from u in User, where: u.id == ^user.id)
      Sandbox.mode(Repo, :manual)
    end)

    {:ok, credentials} = Accounts.create_session(user)
    %{credentials: credentials}
  end

  # Holds the session row locked (as a slow refresh or logout would) while
  # the racers start: every refresh, recovery and logout of a session decides
  # under that lock, so they all queue on it and truly overlap.
  defp lock_session_row(session_id) do
    parent = self()

    gate =
      spawn_link(fn ->
        {:ok, :released} =
          Repo.transaction(fn ->
            Repo.one!(from s in Session, where: s.id == ^session_id, lock: "FOR UPDATE")
            send(parent, :locked)

            receive do
              :release -> :released
            end
          end)

        send(parent, :released)
      end)

    assert_receive :locked, 5_000
    gate
  end

  defp await_lock_waiters(count, attempts \\ 300) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    cond do
      waiting >= count ->
        :ok

      attempts == 0 ->
        flunk("expected #{count} requests blocked on the session row, saw #{waiting}")

      true ->
        Process.sleep(10)
        await_lock_waiters(count, attempts - 1)
    end
  end

  defp race(gate, waiters, funs) do
    tasks = Enum.map(funs, &Task.async/1)
    await_lock_waiters(waiters)
    send(gate, :release)
    assert_receive :released, 5_000
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp live_tokens(session_id),
    do:
      Repo.all(
        from t in RefreshToken, where: t.session_id == ^session_id and is_nil(t.consumed_at)
      )

  test "two concurrent refreshes of one token: one rotates, the other recovers, one chain", %{
    credentials: c
  } do
    gate = lock_session_row(c.session.id)
    refresh = fn -> Accounts.refresh_session(c.refresh_token) end
    results = race(gate, 2, [refresh, refresh])

    # Both requests presented the token the session presented last and no
    # successor was used yet: the second is a recovery, never a second chain.
    assert [{:ok, a}, {:ok, b}] = results
    assert [live] = live_tokens(c.session.id)
    assert Repo.get!(Session, c.session.id).revoked_at == nil

    {winner, superseded} =
      if live.token_hash == :crypto.hash(:sha256, a.refresh_token), do: {a, b}, else: {b, a}

    # The holder of the superseded token collides on its next refresh.
    assert Accounts.refresh_session(superseded.refresh_token) == {:error, :unauthorized}
    assert %Session{revoked_reason: :refresh_reuse} = Repo.get!(Session, c.session.id)
    assert Accounts.refresh_session(winner.refresh_token) == {:error, :unauthorized}
    assert Accounts.authenticate_access_token(winner.access_token) == {:error, :unauthorized}
  end

  test "several concurrent refreshes leave exactly one live token", %{credentials: c} do
    gate = lock_session_row(c.session.id)
    refresh = fn -> Accounts.refresh_session(c.refresh_token) end
    results = race(gate, 4, List.duplicate(refresh, 4))

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert [live] = live_tokens(c.session.id)
    hashes = for {:ok, r} <- results, do: :crypto.hash(:sha256, r.refresh_token)
    assert live.token_hash in hashes

    assert Repo.one!(
             from t in RefreshToken,
               where: t.token_hash == ^:crypto.hash(:sha256, c.refresh_token),
               select: t.recoveries
           ) == 3
  end

  test "concurrent presentations beyond the recovery limit revoke the session", %{
    credentials: c
  } do
    # A small limit keeps every racer on its own pooled connection (CI pools
    # are `schedulers_online * 2`); the rule is the same at the production 10.
    original = Application.get_env(:simple_fit, Sessions)
    on_exit(fn -> Application.put_env(:simple_fit, Sessions, original) end)
    Application.put_env(:simple_fit, Sessions, Keyword.put(original, :refresh_recovery_limit, 2))
    limit = Sessions.config!().refresh_recovery_limit
    gate = lock_session_row(c.session.id)
    refresh = fn -> Accounts.refresh_session(c.refresh_token) end
    results = race(gate, limit + 2, List.duplicate(refresh, limit + 2))

    # One rotation, `limit` recoveries, then reuse: the session is revoked.
    assert Enum.count(results, &match?({:ok, _}, &1)) == limit + 1
    assert Enum.count(results, &(&1 == {:error, :unauthorized})) == 1
    assert %Session{revoked_reason: :refresh_reuse} = Repo.get!(Session, c.session.id)

    for {:ok, r} <- results,
        do: assert(Accounts.authenticate_access_token(r.access_token) == {:error, :unauthorized})
  end

  test "a replay racing the owner after the successor was used is reuse", %{credentials: c} do
    {:ok, second} = Accounts.refresh_session(c.refresh_token)
    gate = lock_session_row(c.session.id)

    results =
      race(gate, 2, [
        fn -> Accounts.refresh_session(second.refresh_token) end,
        fn -> Accounts.refresh_session(c.refresh_token) end
      ])

    # Whatever the order, the stale token never yields a working session.
    assert {:error, :unauthorized} in results
    assert %Session{revoked_reason: :refresh_reuse} = Repo.get!(Session, c.session.id)

    for {:ok, r} <- results,
        do: assert(Accounts.authenticate_access_token(r.access_token) == {:error, :unauthorized})
  end

  test "an immediate replay from several clients after the successor was used revokes", %{
    credentials: c
  } do
    {:ok, second} = Accounts.refresh_session(c.refresh_token)
    {:ok, next} = Accounts.refresh_session(second.refresh_token)

    replays = for _ <- 1..3, do: Task.async(fn -> Accounts.refresh_session(c.refresh_token) end)
    assert Enum.all?(replays, &(Task.await(&1, 5_000) == {:error, :unauthorized}))

    assert %Session{revoked_reason: :refresh_reuse} = Repo.get!(Session, c.session.id)
    assert Accounts.refresh_session(next.refresh_token) == {:error, :unauthorized}
    assert Accounts.authenticate_access_token(next.access_token) == {:error, :unauthorized}
  end

  # SF-28: logout and refresh of the same session at the same time.

  test "logout queued before a refresh: the refresh fails and consumes nothing", %{
    credentials: c
  } do
    gate = lock_session_row(c.session.id)
    logout = Task.async(fn -> Accounts.revoke_session({:access, c.access_token}) end)
    await_lock_waiters(1)
    refresh = Task.async(fn -> Accounts.refresh_session(c.refresh_token) end)
    await_lock_waiters(2)

    send(gate, :release)
    assert_receive :released, 5_000

    assert Task.await(logout, 5_000) == :ok
    assert Task.await(refresh, 5_000) == {:error, :unauthorized}
    assert %Session{revoked_reason: :logout} = Repo.get!(Session, c.session.id)
    assert [_unconsumed] = live_tokens(c.session.id)
    assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
    assert Accounts.authenticate_access_token(c.access_token) == {:error, :unauthorized}
  end

  test "a lost-response recovery racing a logout never outlives the logout", %{credentials: c} do
    {:ok, _lost} = Accounts.refresh_session(c.refresh_token)
    gate = lock_session_row(c.session.id)

    [recovery, :ok] =
      race(gate, 2, [
        fn -> Accounts.refresh_session(c.refresh_token) end,
        fn -> Accounts.revoke_session({:refresh, c.refresh_token}) end
      ])

    assert %Session{revoked_reason: :logout} = Repo.get!(Session, c.session.id)

    case recovery do
      {:ok, r} ->
        assert Accounts.authenticate_access_token(r.access_token) == {:error, :unauthorized}

      {:error, :unauthorized} ->
        :ok
    end
  end

  test "a refresh that won before the logout: its new credentials die with the session", %{
    credentials: c
  } do
    {:ok, rotated} = Accounts.refresh_session(c.refresh_token)

    # The client logs out with what it still holds: the consumed refresh token.
    assert :ok = Accounts.revoke_session({:refresh, c.refresh_token})

    assert %Session{revoked_reason: :logout} = Repo.get!(Session, c.session.id)
    assert Accounts.refresh_session(rotated.refresh_token) == {:error, :unauthorized}
    assert Accounts.authenticate_access_token(rotated.access_token) == {:error, :unauthorized}
  end

  test "concurrent logouts of one session are all :ok and revoke it once", %{credentials: c} do
    logouts =
      for credential <- [
            {:access, c.access_token},
            {:refresh, c.refresh_token},
            {:access, c.access_token}
          ],
          do: Task.async(fn -> Accounts.revoke_session(credential) end)

    assert Enum.all?(logouts, &(Task.await(&1, 5_000) == :ok))
    assert %Session{revoked_reason: :logout} = Repo.get!(Session, c.session.id)
  end
end
