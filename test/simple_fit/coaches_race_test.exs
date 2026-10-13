defmodule SimpleFit.CoachesRaceTest do
  @moduledoc """
  Coach profile writes under true concurrency, on separate database
  connections (outside the SQL sandbox), so row locks and the unique index
  are exercised for real. Rows are committed, so every test removes the users
  it created (profiles cascade).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.AccountRegistrationHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaches
  alias SimpleFit.Coaches.CoachProfile
  alias SimpleFit.Repo

  @required %{
    "display_name" => "Coach Marek",
    "country_code" => "PL",
    "city" => "Warsaw",
    "coaching_formats" => ["personal_training"]
  }

  setup do
    Sandbox.mode(Repo, :auto)
    marker = "coach-race-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from u in User,
          join: i in assoc(u, :identities),
          where: like(i.provider_subject, ^"#{marker}%")
      )

      Sandbox.mode(Repo, :manual)
    end)

    %{marker: marker}
  end

  defp user!(marker, suffix \\ "") do
    {:ok, user} = Accounts.register_user(:google, "#{marker}#{suffix}")
    complete_account_registration!(user)
  end

  defp profiles(user),
    do: Repo.aggregate(from(p in CoachProfile, where: p.user_id == ^user.id), :count)

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(15_000)

  test "simultaneous first saves of different fields create one profile holding both", %{
    marker: marker
  } do
    user = user!(marker)

    results =
      concurrently([
        fn -> Coaches.update_profile(user, %{"display_name" => "Coach Marek"}) end,
        fn -> Coaches.update_profile(user, %{"city" => "Warsaw"}) end,
        fn -> Coaches.update_profile(user, %{"languages" => ["pl"]}) end,
        fn -> Coaches.update_profile(user, %{"coaching_formats" => ["fight_camps"]}) end
      ])

    assert Enum.all?(results, &match?({:ok, %CoachProfile{}}, &1))
    assert results |> Enum.map(fn {:ok, p} -> p.id end) |> Enum.uniq() |> length() == 1
    assert profiles(user) == 1

    profile = Coaches.get_profile(user)
    assert profile.display_name == "Coach Marek"
    assert profile.city == "Warsaw"
    assert profile.languages == [:pl]
    assert profile.coaching_formats == [:fight_camps]
  end

  test "a save waits for a competing transaction holding the row, then keeps its fields", %{
    marker: marker
  } do
    user = user!(marker)
    {:ok, profile} = Coaches.update_profile(user, %{"city" => "Warsaw"})
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(p in CoachProfile, where: p.id == ^profile.id, lock: "FOR UPDATE"))
          Repo.update_all(from(p in CoachProfile, where: p.id == ^profile.id), set: [bio: "Held"])
          send(parent, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held, 5_000
    saver = Task.async(fn -> Coaches.update_profile(user, %{"brand_name" => "Marek Boxing"}) end)

    # The save is blocked on the row lock until the holder commits.
    refute Task.yield(saver, 300)
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder)

    assert {:ok, saved} = Task.await(saver)
    assert saved.brand_name == "Marek Boxing"
    assert saved.bio == "Held"
    assert saved.city == "Warsaw"
  end

  test "simultaneous completions record one completion time", %{marker: marker} do
    user = user!(marker)
    {:ok, _} = Coaches.update_profile(user, @required)

    results = concurrently(for _ <- 1..8, do: fn -> Coaches.complete_onboarding(user) end)

    assert Enum.all?(results, &match?({:ok, %CoachProfile{}}, &1))
    times = results |> Enum.map(fn {:ok, p} -> p.onboarding_completed_at end) |> Enum.uniq()
    assert [%DateTime{} = at] = times
    assert Coaches.get_profile(user).onboarding_completed_at == at
    assert profiles(user) == 1
  end

  test "a save clearing a requirement racing completion never leaves a completed profile without it",
       %{marker: marker} do
    for i <- 1..10 do
      user = user!(marker, "-#{i}")
      {:ok, _} = Coaches.update_profile(user, @required)

      [completion, clearing] =
        concurrently([
          fn -> Coaches.complete_onboarding(user) end,
          fn -> Coaches.update_profile(user, %{"coaching_formats" => []}) end
        ])

      profile = Coaches.get_profile(user)

      case {completion, clearing} do
        # Completion first: the later save may not clear a requirement.
        {{:ok, _}, {:error, _}} ->
          assert profile.onboarding_completed_at
          assert profile.coaching_formats == [:personal_training]

        # Save first: completion then finds the requirement missing.
        {{:error, _}, {:ok, _}} ->
          assert profile.onboarding_completed_at == nil
          assert profile.coaching_formats == []

        other ->
          flunk("unexpected interleaving: #{inspect(other)}")
      end
    end
  end

  test "repeated identical retries converge on one row and one value", %{marker: marker} do
    user = user!(marker)

    results =
      concurrently(
        for _ <- 1..10, do: fn -> Coaches.update_profile(user, %{"city" => "Warsaw"}) end
      )

    assert Enum.all?(results, &match?({:ok, %CoachProfile{city: "Warsaw"}}, &1))
    assert profiles(user) == 1
  end

  test "an invalid concurrent save never rolls back a valid one", %{marker: marker} do
    user = user!(marker)
    {:ok, _} = Coaches.update_profile(user, %{"city" => "Warsaw"})

    [valid, invalid] =
      concurrently([
        fn -> Coaches.update_profile(user, %{"display_name" => "Coach Marek"}) end,
        fn -> Coaches.update_profile(user, %{"city" => "Kraków", "languages" => ["xx"]}) end
      ])

    assert {:ok, _} = valid
    assert {:error, _} = invalid

    profile = Coaches.get_profile(user)
    assert profile.display_name == "Coach Marek"
    assert profile.city == "Warsaw"
  end

  test "different users write their own profiles in parallel", %{marker: marker} do
    users = for i <- 1..6, do: user!(marker, "-u#{i}")

    results =
      concurrently(
        for {user, i} <- Enum.with_index(users) do
          fn ->
            {:ok, _} = Coaches.update_profile(user, Map.put(@required, "city", "City #{i}"))
            Coaches.complete_onboarding(user)
          end
        end
      )

    assert Enum.all?(results, &match?({:ok, %CoachProfile{}}, &1))

    for {user, i} <- Enum.with_index(users) do
      profile = Coaches.get_profile(user)
      assert profile.user_id == user.id
      assert profile.city == "City #{i}"
      assert profiles(user) == 1
    end
  end
end
