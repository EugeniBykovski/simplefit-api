defmodule SimpleFit.Security.AbuseConcurrencyTest do
  @moduledoc """
  Abuse limits under real concurrency (SF-29), on separate database
  connections outside the SQL sandbox, the way parallel requests on several
  app instances reach PostgreSQL. Rows are committed for real and removed
  afterwards.

    * Rate-limit counters are exact: N parallel hits against a limit L let
      exactly L through.
    * A burst of parallel wrong guesses never earns more than the five
      failed attempts a code allows; afterwards even the right code is
      refused.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.EmailAuthHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.{Accounts, RateLimit, Repo}
  alias SimpleFit.Accounts.EmailAuth.Challenge
  alias SimpleFit.Accounts.User

  @ip "198.51.100.29"

  setup do
    Sandbox.mode(Repo, :auto)
    marker = "sf29-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(Challenge)
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "SimpleFit.Email.DeliveryWorker"))
      Repo.delete_all(User)
      Repo.query!("DELETE FROM auth_rate_limits", [])
      Sandbox.mode(Repo, :manual)
    end)

    %{marker: marker}
  end

  test "parallel hits are counted exactly: a limit of 10 lets exactly 10 of 40 through", %{
    marker: marker
  } do
    rule = {"sf29:burst", :crypto.hash(:sha256, marker), 10, 600}

    results =
      1..40
      |> Task.async_stream(fn _ -> RateLimit.hit([rule]) end,
        max_concurrency: 40,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 10
    assert Enum.count(results, &match?({:error, {:rate_limited, _}}, &1)) == 30
  end

  test "a window ends: the same key is allowed again in the next window", %{marker: marker} do
    rule = {"sf29:window", :crypto.hash(:sha256, marker), 1, 60}
    now = ~U[2026-10-11 12:00:30Z]

    assert RateLimit.hit([rule], now) == :ok
    assert {:error, {:rate_limited, 30}} = RateLimit.hit([rule], now)
    assert RateLimit.hit([rule], DateTime.add(now, 30)) == :ok
  end

  test "a burst of parallel wrong codes gets no more than five tries", %{marker: marker} do
    email = "#{marker}@example.com"
    {:ok, %{registration_token: token}} = Accounts.request_email_registration(email, @ip)

    {:ok, _credentials} =
      Accounts.verify_email_registration_code(token, code_from(last_email_to(email)), @ip)

    reset_rate_limits()
    {:ok, _} = Accounts.request_email_sign_in(email, @ip)
    code = code_from(last_email_to(email))
    guesses = Enum.map(1..30, &rem(String.to_integer(code) + &1, 1_000_000))

    results =
      guesses
      |> Task.async_stream(
        fn guess ->
          Accounts.verify_email_sign_in_code(
            email,
            guess |> Integer.to_string() |> String.pad_leading(6, "0"),
            "203.0.113.#{rem(guess, 250)}"
          )
        end,
        max_concurrency: 30,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # Every guess fails, and at most five were judged against the code: the
    # rest found it exhausted (code_expired) or lost no attempt at all.
    assert Enum.all?(
             results,
             &match?({:error, reason} when reason in [:code_invalid, :code_expired], &1)
           )

    assert Enum.count(results, &(&1 == {:error, :code_invalid})) <= 5

    # Exhausted: the right code no longer signs in.
    assert {:error, :code_expired} = Accounts.verify_email_sign_in_code(email, code, @ip)
  end
end
