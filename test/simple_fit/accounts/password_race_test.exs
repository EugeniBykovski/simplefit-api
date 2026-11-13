defmodule SimpleFit.Accounts.PasswordRaceTest do
  @moduledoc """
  SF-157 under true concurrency: competing password resets and changes run in
  separate processes, on separate connections outside the SQL sandbox, so
  PostgreSQL row locks decide. Rows are committed; every test removes them.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.EmailAuthHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.EmailAuth.Challenge
  alias SimpleFit.Accounts.{PasswordCredential, SecurityEvent, Session, User}
  alias SimpleFit.Repo

  @ip "203.0.113.58"

  setup do
    Sandbox.mode(Repo, :auto)
    marker = "pwrace#{System.unique_integer([:positive])}"
    started = DateTime.add(DateTime.utc_now(), -5)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      users =
        from(u in User,
          join: i in assoc(u, :identities),
          where: like(i.provider_subject, ^"%#{marker}%"),
          select: u.id
        )

      Repo.delete_all(from(u in User, where: u.id in subquery(users)))
      Repo.delete_all(from(c in Challenge, where: c.inserted_at >= ^started))
      Repo.delete_all(from(j in Oban.Job, where: j.inserted_at >= ^DateTime.to_naive(started)))
      Repo.query!("DELETE FROM auth_rate_limits", [])
      Sandbox.mode(Repo, :manual)
    end)

    address = "#{marker}@example.com"
    {:ok, user} = Accounts.register_user(:email, address)
    %{address: address, user: user}
  end

  defp concurrently(count, fun) do
    1..count
    |> Enum.map(fn n -> Task.async(fn -> fun.(n) end) end)
    |> Task.await_many(15_000)
  end

  defp code!(address) do
    {:ok, _} = Accounts.request_password_reset(address, @ip)
    code_from(last_email_to(address))
  end

  test "one code, many resets at once: exactly one wins; the others find it used", %{
    address: address,
    user: user
  } do
    for _round <- 1..3 do
      reset_rate_limits()
      code = code!(address)

      results =
        concurrently(6, fn n ->
          Accounts.reset_password(address, code, "concurrent passphrase #{n}", @ip)
        end)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.all?(results -- [:ok], &(&1 == {:error, :code_expired}))
    end

    assert Repo.aggregate(from(c in PasswordCredential, where: c.user_id == ^user.id), :count) ==
             1

    assert Repo.aggregate(from(e in SecurityEvent, where: e.user_id == ^user.id), :count) == 3
  end

  test "a change and a reset at once: both commit in order, and no session outlives the reset", %{
    address: address,
    user: user
  } do
    :ok = Accounts.reset_password(address, code!(address), "first long passphrase", @ip)

    for _round <- 1..10 do
      reset_rate_limits()
      current = Repo.one!(from(c in PasswordCredential, where: c.user_id == ^user.id))
      {:ok, %{session: session}} = Accounts.create_session(user)
      code = code!(address)

      [change, reset] =
        concurrently(2, fn
          1 ->
            Accounts.change_password(
              user,
              session,
              current_password(current),
              "changed passphrase!!"
            )

          2 ->
            Accounts.reset_password(address, code, "reset passphrase!!!", @ip)
        end)

      assert reset == :ok
      # The change either committed first (then the reset revoked its session too)
      # or found the password replaced or its session revoked.
      assert change in [:ok, {:error, :conflict}, {:error, :unauthorized}]

      assert Repo.aggregate(
               from(s in Session, where: s.user_id == ^user.id and is_nil(s.revoked_at)),
               :count
             ) == 0

      # The reset is the last word.
      assert {:ok, _} = Accounts.password_sign_in(address, "reset passphrase!!!", @ip)

      Repo.update_all(from(s in Session, where: s.user_id == ^user.id and is_nil(s.revoked_at)),
        set: [revoked_at: DateTime.truncate(DateTime.utc_now(), :second), revoked_reason: :logout]
      )

      reset_rate_limits()
      :ok = Accounts.reset_password(address, code!(address), "first long passphrase", @ip)
    end
  end

  # The tests know the password each round starts from.
  defp current_password(_credential), do: "first long passphrase"
end
