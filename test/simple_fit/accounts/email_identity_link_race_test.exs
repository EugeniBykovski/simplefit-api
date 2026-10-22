defmodule SimpleFit.Accounts.EmailIdentityLinkRaceTest do
  @moduledoc """
  Verified email identity linking under true concurrency (SF-77, ADR 0024):
  competing calls run in separate processes on separate database
  connections outside the SQL sandbox, so PostgreSQL row locks, foreign
  keys and the identity unique index decide for real. Rows are committed,
  so every test removes what it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.EmailAuthHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.EmailAuth.Challenge
  alias SimpleFit.Accounts.{Identity, Sessions, User}
  alias SimpleFit.Repo

  @ip "203.0.113.90"

  setup do
    Sandbox.mode(Repo, :auto)
    marker = "linkrace#{System.unique_integer([:positive])}"
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

    %{marker: marker, started: started}
  end

  defp concurrently(funs) do
    funs
    |> Enum.map(&Task.async/1)
    |> Task.await_many(15_000)
  end

  defp google_viewer(marker) do
    {:ok, user} =
      Accounts.register_user(:google, "#{marker}-g#{System.unique_integer([:positive])}")

    {:ok, credentials} = Accounts.create_session(user)
    {:ok, viewer} = Accounts.authenticate_access_token(credentials.access_token)
    Map.put(viewer, :access_token, credentials.access_token)
  end

  defp request!(viewer, email) do
    reset_rate_limits()
    {:ok, _} = Accounts.request_email_identity_link(viewer.user, viewer.session, email, @ip)
    code_from(last_email_to(email))
  end

  defp confirm(viewer, email, code, ip \\ @ip),
    do: Accounts.confirm_email_identity_link(viewer.user, viewer.session, email, code, ip)

  defp owners(email) do
    Repo.all(
      from(i in Identity,
        where: i.provider == :email and i.provider_subject == ^email,
        select: i.user_id
      )
    )
  end

  defp wrong(code), do: code |> String.to_integer() |> Kernel.+(1) |> rem(1_000_000) |> pad()
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  test "L: concurrent confirmations of one code link exactly once", %{marker: m} do
    viewer = google_viewer(m)
    email = "#{m}-l@example.com"
    code = request!(viewer, email)

    results =
      concurrently(for n <- 1..8, do: fn -> confirm(viewer, email, code, "198.51.100.#{n}") end)

    assert Enum.count(results, &match?({:ok, %{outcome: :linked}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :code_expired})) == 7
    assert owners(email) == [viewer.user.id]
  end

  test "E: two users racing for one address: one owner, the other a conflict", %{marker: m} do
    for round <- 1..10 do
      a = google_viewer(m)
      b = google_viewer(m)
      email = "#{m}-e#{round}@example.com"
      code_a = request!(a, email)
      code_b = request!(b, email)

      results =
        concurrently([
          fn -> {a, confirm(a, email, code_a)} end,
          fn -> {b, confirm(b, email, code_b)} end
        ])

      assert [{winner, {:ok, %{outcome: :linked}}}] =
               Enum.filter(results, &match?({_, {:ok, _}}, &1))

      assert [{_loser, {:error, :conflict}}] = Enum.filter(results, &match?({_, {:error, _}}, &1))
      assert owners(email) == [winner.user.id]
      # Each user keeps exactly its own Google identity.
      for v <- [a, b],
          do:
            assert(
              Repo.aggregate(
                from(i in Identity, where: i.user_id == ^v.user.id and i.provider == :google),
                :count
              ) == 1
            )
    end
  end

  test "a link racing an email registration of the same address: one owner, no orphan user",
       %{marker: m, started: started} do
    for round <- 1..10 do
      viewer = google_viewer(m)
      email = "#{m}-r#{round}@example.com"
      link_code = request!(viewer, email)
      reset_rate_limits()
      {:ok, %{registration_token: token}} = Accounts.request_email_registration(email, @ip)
      registration_code = code_from(last_email_to(email))

      [linked, registered] =
        concurrently([
          fn -> confirm(viewer, email, link_code) end,
          fn -> Accounts.verify_email_registration_code(token, registration_code, @ip) end
        ])

      assert [owner] = owners(email)

      case linked do
        {:ok, %{outcome: :linked}} ->
          assert owner == viewer.user.id
          assert registered == {:error, :conflict}

        {:error, :conflict} ->
          assert {:ok, %{session: %{user_id: ^owner}}} = registered
      end

      # No user without an identity was left behind by the loser.
      orphans =
        Repo.aggregate(
          from(u in User,
            left_join: i in assoc(u, :identities),
            where: is_nil(i.id) and u.inserted_at >= ^DateTime.truncate(started, :second)
          ),
          :count
        )

      assert orphans == 0
    end
  end

  test "J: logout racing a confirmation: linked before it, or refused after it", %{marker: m} do
    outcomes =
      for round <- 1..15 do
        viewer = google_viewer(m)
        email = "#{m}-j#{round}@example.com"
        code = request!(viewer, email)

        [result, :ok] =
          concurrently([
            fn -> confirm(viewer, email, code) end,
            fn -> Accounts.revoke_session({:access, viewer.access_token}) end
          ])

        case result do
          {:ok, %{outcome: :linked}} -> assert owners(email) == [viewer.user.id]
          {:error, :unauthorized} -> assert owners(email) == []
        end

        # Either way the session is over and the next attempt is refused.
        assert {:error, :unauthorized} = Accounts.authenticate_access_token(viewer.access_token)
        assert confirm(viewer, email, code) == {:error, :unauthorized}
        elem(result, 0)
      end

    assert Enum.all?(outcomes, &(&1 in [:ok, :error]))
  end

  test "account deletion racing a confirmation never leaves an identity without its user",
       %{marker: m} do
    for round <- 1..10 do
      viewer = google_viewer(m)
      email = "#{m}-d#{round}@example.com"
      code = request!(viewer, email)

      [result, _deleted] =
        concurrently([
          fn -> confirm(viewer, email, code) end,
          fn -> Repo.delete_all(from(u in User, where: u.id == ^viewer.user.id)) end
        ])

      assert result in [{:error, :unauthorized}] or match?({:ok, %{outcome: :linked}}, result)
      # The user is gone, and with it every identity and challenge it had.
      assert owners(email) == []
      assert Repo.all(from(c in Challenge, where: c.user_id == ^viewer.user.id)) == []
    end
  end

  test "concurrent requests of one user: one open challenge, counted exactly", %{marker: m} do
    viewer = google_viewer(m)
    reset_rate_limits()

    results =
      concurrently(
        for n <- 1..8 do
          fn ->
            Accounts.request_email_identity_link(
              viewer.user,
              viewer.session,
              "#{m}-q#{n}@example.com",
              "198.51.100.#{n}"
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:rate_limited, _}}, &1)) == 7

    open =
      Repo.all(
        from(c in Challenge,
          where: c.user_id == ^viewer.user.id and is_nil(c.closed_at)
        )
      )

    assert length(open) == 1
  end

  test "30 parallel wrong guesses: exactly 5 counted, then even the right code fails",
       %{marker: m} do
    viewer = google_viewer(m)
    email = "#{m}-burst@example.com"
    code = request!(viewer, email)

    results =
      concurrently(
        for n <- 1..30, do: fn -> confirm(viewer, email, wrong(code), "198.51.100.#{n}") end
      )

    assert Enum.count(results, &(&1 == {:error, :code_invalid})) == 5
    assert Enum.count(results, &(&1 == {:error, :code_expired})) == 25

    assert [%Challenge{failed_attempts: 5, closed_reason: :exhausted}] =
             Repo.all(from(c in Challenge, where: c.user_id == ^viewer.user.id))

    assert confirm(viewer, email, code) == {:error, :code_expired}
    assert owners(email) == []
  end

  test "S: refresh rotation is unaffected by a pending or confirmed link", %{marker: m} do
    {:ok, user} = Accounts.register_user(:google, "#{m}-s")
    {:ok, credentials} = Accounts.create_session(user)
    {:ok, viewer} = Accounts.authenticate_access_token(credentials.access_token)
    email = "#{m}-s@example.com"
    code = request!(viewer, email)

    assert {:ok, rotated} = Sessions.refresh(credentials.refresh_token)
    assert rotated.session.id == viewer.session.id
    assert {:ok, %{outcome: :linked}} = confirm(viewer, email, code)
    assert {:ok, _} = Sessions.refresh(rotated.refresh_token)
  end
end
