defmodule SimpleFit.Accounts.AppleAuthRaceTest do
  @moduledoc """
  Concurrent first Apple sign-ins on separate database connections: the
  SF-19 unique index decides, exactly one user owns the Apple identity, and
  no orphan user is left.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.AppleTokens

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{Identity, User}
  alias SimpleFit.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    reset()
    stub_jwks(self())
    sub = "race#{System.unique_integer([:positive])}"
    users_before = Repo.aggregate(User, :count)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from(u in User,
          where:
            u.id in subquery(
              from(i in Identity, where: i.provider_subject == ^sub, select: i.user_id)
            )
        )
      )

      Repo.query!("DELETE FROM auth_rate_limits", [])
      Sandbox.mode(Repo, :manual)
    end)

    %{sub: sub, users_before: users_before}
  end

  test "concurrent first sign-ins resolve exactly one user, with a session each", %{
    sub: sub,
    users_before: users_before
  } do
    %{id_token: token, nonce: nonce} = credential(sub)

    results =
      1..8
      |> Enum.map(fn n ->
        Task.async(fn -> Accounts.authenticate_with_apple(token, nonce, "198.51.100.#{n}") end)
      end)
      |> Task.await_many(20_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    accounts = Enum.map(results, fn {:ok, %{account: account}} -> account end)
    assert Enum.count(accounts, &(&1 == :created)) == 1

    user_ids =
      results |> Enum.map(fn {:ok, %{credentials: c}} -> c.session.user_id end) |> Enum.uniq()

    assert [_one] = user_ids

    assert Repo.aggregate(from(i in Identity, where: i.provider_subject == ^sub), :count) == 1
    # No orphan user from the losing registrations.
    assert Repo.aggregate(User, :count) == users_before + 1
  end
end
