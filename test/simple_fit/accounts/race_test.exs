defmodule SimpleFit.Accounts.RaceTest do
  @moduledoc """
  True concurrency on separate database connections (outside the SQL
  sandbox): a competing transaction holds the identity uncommitted, the domain
  call blocks on the unique index, and the competitor commits. The domain must
  turn the losing insert into a deterministic result and leave nothing
  behind. Rows are committed for real, so every test removes what it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{Identity, User}
  alias SimpleFit.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    marker = "race-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from u in User,
          join: i in assoc(u, :identities),
          where: like(i.provider_subject, ^"%#{marker}%")
      )

      Sandbox.mode(Repo, :manual)
    end)

    %{marker: marker}
  end

  # Inserts the identity for `user` in a transaction that stays open until
  # `commit/1`, from its own process and therefore its own connection.
  defp hold_identity(user, provider, subject) do
    parent = self()

    competitor =
      spawn_link(fn ->
        {:ok, :committed} =
          Repo.transaction(fn ->
            Repo.insert!(%Identity{
              user_id: user.id,
              provider: provider,
              provider_subject: subject
            })

            send(parent, :held)

            receive do
              :commit -> :committed
            end
          end)

        send(parent, :committed)
      end)

    assert_receive :held, 5_000
    competitor
  end

  defp commit(competitor) do
    send(competitor, :commit)
    assert_receive :committed, 5_000
  end

  # Waits until another backend is blocked on a lock (our domain insert
  # waiting for the competitor's uncommitted row).
  defp await_lock_wait(attempts \\ 200) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    cond do
      waiting > 0 ->
        :ok

      attempts == 0 ->
        flunk("the domain call never blocked on the unique index")

      true ->
        Process.sleep(10)
        await_lock_wait(attempts - 1)
    end
  end

  test "register_user/2 losing a real race rolls back its user and reports a conflict", %{
    marker: marker
  } do
    {:ok, winner} = Accounts.register_user(:google, "winner-#{marker}")
    subject = "#{marker}@example.com"
    users_before = Repo.aggregate(User, :count)

    competitor = hold_identity(winner, :email, subject)
    loser = Task.async(fn -> Accounts.register_user(:email, subject) end)
    await_lock_wait()
    commit(competitor)

    assert Task.await(loser, 5_000) == {:error, :conflict}
    # The loser's user row was rolled back with its failed identity.
    assert Repo.aggregate(User, :count) == users_before
    assert {:ok, %User{id: owner}} = Accounts.resolve_user(:email, subject)
    assert owner == winner.id
  end

  test "link_identity/3 losing a real race to another user is a conflict", %{marker: marker} do
    {:ok, alice} = Accounts.register_user(:google, "alice-#{marker}")
    {:ok, bob} = Accounts.register_user(:google, "bob-#{marker}")
    subject = "shared-#{marker}"

    competitor = hold_identity(alice, :apple, subject)
    loser = Task.async(fn -> Accounts.link_identity(bob, :apple, subject) end)
    await_lock_wait()
    commit(competitor)

    assert Task.await(loser, 5_000) == {:error, :conflict}
    assert {:ok, %User{id: owner}} = Accounts.resolve_user(:apple, subject)
    assert owner == alice.id
  end

  test "link_identity/3 racing the same user resolves to the existing identity", %{marker: marker} do
    {:ok, alice} = Accounts.register_user(:google, "alice-#{marker}")
    subject = "same-#{marker}"

    competitor = hold_identity(alice, :apple, subject)
    linker = Task.async(fn -> Accounts.link_identity(alice, :apple, subject) end)
    await_lock_wait()
    commit(competitor)

    assert {:ok, %Identity{user_id: user_id, provider: :apple}} = Task.await(linker, 5_000)
    assert user_id == alice.id

    assert Repo.aggregate(from(i in Identity, where: i.provider_subject == ^subject), :count) == 1
  end
end
