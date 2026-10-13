defmodule SimpleFit.EntryContextRaceTest do
  @moduledoc """
  The explicit context choice under true concurrency, on separate database
  connections (outside the SQL sandbox): one row per user, the last committed
  choice wins, users never overwrite each other. Rows are committed, so every
  test removes the users it created (choices cascade).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.FighterOnboardingHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaches
  alias SimpleFit.Entry
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Repo

  @coach %{
    "display_name" => "Coach Marek",
    "country_code" => "PL",
    "city" => "Warsaw",
    "coaching_formats" => ["personal_training"]
  }

  setup do
    Sandbox.mode(Repo, :auto)
    marker = "entry-race-#{System.unique_integer([:positive])}"

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

  defp dual_user!(marker, suffix) do
    {:ok, user} = Accounts.register_user(:google, "#{marker}#{suffix}")
    complete_fighter_onboarding!(user)
    {:ok, _} = Coaches.update_profile(user, @coach)
    {:ok, _} = Coaches.complete_onboarding(user)
    user
  end

  defp choices(user),
    do: Repo.all(from(c in ContextChoice, where: c.user_id == ^user.id))

  test "concurrent first choices create exactly one row holding one of them", %{marker: marker} do
    user = dual_user!(marker, "-a")

    results =
      for context <- List.duplicate("coach", 6) ++ List.duplicate("fighter", 6) do
        Task.async(fn -> Entry.record_context_choice(user, %{"context" => context}) end)
      end
      |> Task.await_many(15_000)

    assert Enum.all?(results, &match?({:ok, %ContextChoice{}}, &1))
    assert [%ContextChoice{context: stored}] = choices(user)
    assert stored in [:fighter, :coach]

    # The entry follows whatever was committed last, deterministically.
    {:ok, entry} = Entry.resolve(user)
    assert entry.destination == if(stored == :coach, do: :coach_home, else: :fighter_home)
  end

  test "sequential changes from two devices: the latest wins", %{marker: marker} do
    user = dual_user!(marker, "-b")

    for context <- ["coach", "fighter", "coach"] do
      Task.async(fn -> Entry.record_context_choice(user, %{"context" => context}) end)
      |> Task.await()
    end

    assert [%ContextChoice{context: :coach}] = choices(user)
  end

  test "users choosing at the same time never overwrite each other", %{marker: marker} do
    users = for i <- 1..6, do: dual_user!(marker, "-u#{i}")

    users
    |> Enum.with_index()
    |> Enum.map(fn {user, i} ->
      context = if rem(i, 2) == 0, do: "coach", else: "fighter"

      Task.async(fn ->
        {user, context, Entry.record_context_choice(user, %{"context" => context})}
      end)
    end)
    |> Task.await_many(15_000)
    |> Enum.each(fn {user, context, {:ok, _}} ->
      assert [%ContextChoice{context: stored}] = choices(user)
      assert Atom.to_string(stored) == context
    end)
  end
end
