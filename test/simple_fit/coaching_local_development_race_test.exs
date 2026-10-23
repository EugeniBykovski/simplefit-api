defmodule SimpleFit.CoachingLocalDevelopmentRaceTest do
  @moduledoc """
  LOCAL DEVELOPMENT mode (SF-81, ADR 0025) under true concurrency, on
  separate connections outside the SQL sandbox: the mode removes the legal
  documents only, never the locking. One token accepted at once by many
  requests creates one relationship; an acceptance racing a decline settles
  on exactly one outcome. Rows are committed, so each test removes its users.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaches, Coaching, Repo}
  alias SimpleFit.Coaching.{Invitation, LocalDevelopment, Relationship}

  @ip "198.51.100.81"
  @marker "local-development-no-legal-text"

  setup do
    Sandbox.mode(Repo, :auto)
    configure_sharing(enabled: false, disclosures: %{}, current: nil, data_rules: nil)
    LocalDevelopment.put_active_for_test(true)
    reset_rate_limits()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
      LocalDevelopment.put_active_for_test(false)
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "SimpleFit.Email.DeliveryWorker"))
      reset_rate_limits()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    %{users: users}
  end

  defp track(user, users) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp address, do: "dev-race-#{System.unique_integer([:positive])}@example.com"
  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(15_000)

  defp accept(user, token),
    do:
      Coaching.accept_invitation(
        user,
        %{"token" => token, "disclosure_version" => @marker},
        @ip
      )

  defp invite(coach, to) do
    {:ok, invitation, :created} = Coaching.invite(coach, %{"email" => to}, @ip)
    {invitation, last_token_to(to)}
  end

  defp active(coach) do
    profile = Coaches.get_profile(coach).id

    Repo.aggregate(
      from(r in Relationship, where: r.coach_profile_id == ^profile and r.status == :active),
      :count
    )
  end

  test "simultaneous acceptances with one token: one relationship, the rest unavailable", %{
    users: users
  } do
    coach = coach_user!() |> track(users)
    to = address()
    {invitation, token} = invite(coach, to)
    fighter = email_fighter!(to) |> track(users)

    results = concurrently(for _ <- 1..8, do: fn -> accept(fighter, token) end)

    assert Enum.count(results, &match?({:ok, %{outcome: :created}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invitation_unavailable})) == 7
    assert active(coach) == 1
    assert Repo.get!(Invitation, invitation.id).accepted_disclosure_version == @marker
  end

  test "accept racing decline: exactly one outcome, consistent", %{users: users} do
    coach = coach_user!() |> track(users)
    to = address()
    {invitation, token} = invite(coach, to)
    fighter = email_fighter!(to) |> track(users)

    [accepted, declined] =
      concurrently([
        fn -> accept(fighter, token) end,
        fn -> Coaching.decline_invitation(fighter, %{"token" => token}, @ip) end
      ])

    invitation = Repo.get!(Invitation, invitation.id)

    case invitation.status do
      :accepted ->
        assert {:ok, %{outcome: :created}} = accepted
        assert declined == {:error, :invitation_unavailable}
        assert active(coach) == 1

      :declined ->
        assert declined == :ok
        assert accepted == {:error, :invitation_unavailable}
        assert active(coach) == 0
    end
  end
end
