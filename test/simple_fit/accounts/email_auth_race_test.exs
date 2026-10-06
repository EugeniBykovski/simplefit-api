defmodule SimpleFit.Accounts.EmailAuthRaceTest do
  @moduledoc """
  Email authentication under true concurrency (ADR 0012): competing
  requests run in separate processes, on separate database connections
  outside the SQL sandbox, so PostgreSQL row locks and unique indexes decide
  for real. Rows are committed, so every test removes what it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.EmailAuthHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.EmailAuth.{Challenge, Secrets}
  alias SimpleFit.Accounts.{Identity, Session, User}
  alias SimpleFit.{RateLimit, Repo}

  @ip "203.0.113.50"

  setup do
    Sandbox.mode(Repo, :auto)
    marker = "race#{System.unique_integer([:positive])}"
    started = DateTime.add(DateTime.utc_now(), -5)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      users =
        from(u in User,
          join: i in assoc(u, :identities),
          where: like(i.provider_subject, ^"%#{marker}%")
        )

      Repo.delete_all(from(u in User, where: u.id in subquery(from(u in users, select: u.id))))
      Repo.delete_all(from(c in Challenge, where: c.inserted_at >= ^started))
      Repo.delete_all(from(j in Oban.Job, where: j.inserted_at >= ^DateTime.to_naive(started)))
      Repo.query!("DELETE FROM auth_rate_limits", [])
      Sandbox.mode(Repo, :manual)
    end)

    %{marker: marker}
  end

  defp concurrently(count, fun) do
    1..count
    |> Enum.map(fn n -> Task.async(fn -> fun.(n) end) end)
    |> Task.await_many(15_000)
  end

  defp sessions_of(email) do
    Repo.aggregate(
      from(s in Session,
        join: i in Identity,
        on: i.user_id == s.user_id,
        where: i.provider == :email and i.provider_subject == ^email
      ),
      :count
    )
  end

  defp users_of(email) do
    Repo.aggregate(
      from(i in Identity, where: i.provider == :email and i.provider_subject == ^email),
      :count
    )
  end

  test "concurrent correct registration codes: exactly one user and one session", %{marker: m} do
    email = "#{m}@example.com"
    {:ok, %{registration_token: token}} = Accounts.request_email_registration(email, @ip)
    code = code_from(last_email_to(email))

    results =
      concurrently(8, fn n ->
        Accounts.verify_email_registration_code(token, code, "198.51.100.#{n}")
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 == {:error, :code_expired}))
    assert users_of(email) == 1
    assert sessions_of(email) == 1
  end

  test "code and link at the same time: one verification, never a link session", %{marker: m} do
    email = "#{m}@example.com"
    {:ok, %{registration_token: token}} = Accounts.request_email_registration(email, @ip)
    message = last_email_to(email)

    [code_result, link_result] =
      concurrently(2, fn
        1 -> Accounts.verify_email_registration_code(token, code_from(message), "198.51.100.1")
        2 -> Accounts.verify_email_link(link_token_from(message), "198.51.100.2")
      end)

    assert users_of(email) == 1

    case {code_result, link_result} do
      {{:ok, _credentials}, {:ok, :already_verified}} ->
        assert sessions_of(email) == 1

      {{:error, :verified_elsewhere}, {:ok, :verified}} ->
        assert sessions_of(email) == 0

      other ->
        flunk("unexpected outcome #{inspect(other)}")
    end
  end

  test "concurrent correct sign-in codes: exactly one session", %{marker: m} do
    email = "#{m}@example.com"
    {:ok, _user} = Accounts.register_user(:email, email)
    {:ok, _} = Accounts.request_email_sign_in(email, @ip)
    code = code_from(last_email_to(email))

    results =
      concurrently(8, fn n ->
        Accounts.verify_email_sign_in_code(email, code, "198.51.100.#{n}")
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 == {:error, :code_expired}))
    assert sessions_of(email) == 1
  end

  test "concurrent requests for one address leave exactly one open challenge", %{marker: m} do
    email = "#{m}@example.com"

    results =
      concurrently(6, fn n -> Accounts.request_email_registration(email, "198.51.100.#{n}") end)

    assert Enum.all?(results, &(match?({:ok, _}, &1) or match?({:error, {:rate_limited, _}}, &1)))
    assert Enum.any?(results, &match?({:ok, _}, &1))

    digest = Secrets.target_digest(email)

    open =
      Repo.aggregate(
        from(c in Challenge, where: c.target_digest == ^digest and is_nil(c.closed_at)),
        :count
      )

    assert open == 1
  end

  test "concurrent supersession: the database never holds two open challenges", %{marker: m} do
    email = "#{m}@example.com"

    # Bypasses the per-target limit on purpose: only the database arbitrates.
    results =
      concurrently(6, fn _n ->
        reset_rate_limits()

        Accounts.request_email_registration(
          email,
          "198.51.100.#{System.unique_integer([:positive]) |> rem(250)}"
        )
      end)

    assert Enum.any?(results, &match?({:ok, _}, &1))
    digest = Secrets.target_digest(email)

    assert Repo.aggregate(
             from(c in Challenge, where: c.target_digest == ^digest and is_nil(c.closed_at)),
             :count
           ) == 1
  end

  test "concurrent rate-limit hits are counted exactly" do
    key = :crypto.strong_rand_bytes(32)

    results = concurrently(20, fn _n -> RateLimit.hit([{"race_test", key, 5, 600}]) end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:error, {:rate_limited, _}}, &1)) == 15
  end
end
