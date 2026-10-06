defmodule SimpleFit.Accounts.SessionRaceTest do
  @moduledoc """
  Refresh rotation under real concurrency, on separate database connections
  (outside the SQL sandbox). A gate transaction holds the refresh token row
  locked while two refreshes of the same token start; both block on the row
  lock, so they truly overlap. Releasing the gate lets them race: exactly one
  rotates the token and the other presents a consumed token, which is reuse
  (strict rotation, no grace window). Rows are committed for real and removed
  afterwards.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{RefreshToken, Session, User}
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

  defp lock_token_row(refresh_token) do
    parent = self()
    hash = :crypto.hash(:sha256, refresh_token)

    gate =
      spawn_link(fn ->
        {:ok, :released} =
          Repo.transaction(fn ->
            Repo.one!(from t in RefreshToken, where: t.token_hash == ^hash, lock: "FOR UPDATE")
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
        flunk("expected #{count} refreshes blocked on the token row, saw #{waiting}")

      true ->
        Process.sleep(10)
        await_lock_waiters(count, attempts - 1)
    end
  end

  test "two concurrent refreshes of one token: one rotates, the loser is reuse", %{credentials: c} do
    gate = lock_token_row(c.refresh_token)
    racers = for _ <- 1..2, do: Task.async(fn -> Accounts.refresh_session(c.refresh_token) end)
    await_lock_waiters(2)

    send(gate, :release)
    assert_receive :released, 5_000
    results = Enum.map(racers, &Task.await(&1, 5_000))

    # Exactly one rotation; never two live successors.
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :unauthorized})) == 1

    live =
      Repo.all(
        from t in RefreshToken, where: t.session_id == ^c.session.id and is_nil(t.consumed_at)
      )

    assert length(live) <= 1

    # The loser presented a consumed token: reuse revokes the session, so the
    # winner's successor cannot continue it either. Intentional.
    assert %Session{revoked_reason: :refresh_reuse} = Repo.get!(Session, c.session.id)
    assert Accounts.refresh_session(winner.refresh_token) == {:error, :unauthorized}
    assert Accounts.authenticate_access_token(winner.access_token) == {:error, :unauthorized}
  end

  test "an immediate replay from several clients revokes the session", %{credentials: c} do
    {:ok, next} = Accounts.refresh_session(c.refresh_token)

    replays = for _ <- 1..3, do: Task.async(fn -> Accounts.refresh_session(c.refresh_token) end)
    assert Enum.all?(replays, &(Task.await(&1, 5_000) == {:error, :unauthorized}))

    assert %Session{revoked_reason: :refresh_reuse} = Repo.get!(Session, c.session.id)
    assert Accounts.refresh_session(next.refresh_token) == {:error, :unauthorized}
    assert Accounts.authenticate_access_token(next.access_token) == {:error, :unauthorized}
  end
end
