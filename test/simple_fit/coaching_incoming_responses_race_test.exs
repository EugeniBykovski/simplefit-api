defmodule SimpleFit.CoachingIncomingResponsesRaceTest do
  @moduledoc """
  Responding by invitation id (SF-73) under true concurrency, on separate
  database connections outside the SQL sandbox: the id path shares the
  SF-57 locked transaction, so the invitation outcome, the accepted
  disclosure and the relationship always commit together, and racing
  responses (by id, by token, decline, cancel, resend, expiry) resolve to
  exactly one outcome. Rows are committed, so every test removes the users
  it created (profiles, relationships and invitations cascade).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaches, Coaching, Repo}
  alias SimpleFit.Coaching.{Invitation, Relationship}

  @ip "198.51.100.73"

  setup do
    Sandbox.mode(Repo, :auto)
    configure_sharing(id_acceptance: true)
    reset_rate_limits()
    {:ok, users} = Agent.start(fn -> [] end)

    on_exit(fn ->
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

  defp address, do: "race-id-#{System.unique_integer([:positive])}@example.com"
  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(15_000)

  defp accept_id(user, id),
    do: Coaching.accept_incoming_invitation(user, id, %{"disclosure_version" => version()}, @ip)

  defp accept_token(user, token),
    do:
      Coaching.accept_invitation(
        user,
        %{"token" => token, "disclosure_version" => version()},
        @ip
      )

  defp coach!(users), do: inviting_coach!() |> track(users)
  defp fighter!(users, to), do: email_fighter!(to) |> track(users)

  defp setup_pair(users) do
    reset_rate_limits()
    coach = coach!(users)
    to = address()
    {invitation, token} = invite!(coach, to)
    {coach, fighter!(users, to), invitation, token, to}
  end

  defp active(coach) do
    profile = Coaches.get_profile(coach).id

    Repo.aggregate(
      from(r in Relationship, where: r.coach_profile_id == ^profile and r.status == :active),
      :count
    )
  end

  defp consistent!(%Invitation{id: id}) do
    invitation = Repo.get!(Invitation, id)

    case invitation.status do
      :accepted ->
        assert invitation.accepted_disclosure_version == version()
        assert Repo.get!(Relationship, invitation.relationship_id).status == :active

      _other ->
        assert invitation.accepted_disclosure_version == nil
        assert invitation.relationship_id == nil
    end

    invitation
  end

  test "ten simultaneous acceptances by id: one relationship, nine unavailable", %{users: users} do
    {coach, fighter, invitation, _token, _to} = setup_pair(users)

    results = concurrently(for _ <- 1..10, do: fn -> accept_id(fighter, invitation.id) end)

    assert Enum.count(results, &match?({:ok, %{outcome: :created}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invitation_unavailable})) == 9
    assert active(coach) == 1
    assert consistent!(invitation).status == :accepted
  end

  test "acceptance by id racing acceptance by token: one relationship", %{users: users} do
    for _ <- 1..5 do
      {coach, fighter, invitation, token, _to} = setup_pair(users)

      results =
        concurrently([
          fn -> accept_id(fighter, invitation.id) end,
          fn -> accept_token(fighter, token) end
        ])

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invitation_unavailable})) == 1
      assert active(coach) == 1
      assert consistent!(invitation).status == :accepted
    end
  end

  test "accept racing decline by id: exactly one outcome, consistent", %{users: users} do
    for _ <- 1..6 do
      {coach, fighter, invitation, _token, _to} = setup_pair(users)

      [accepted, declined] =
        concurrently([
          fn -> accept_id(fighter, invitation.id) end,
          fn -> Coaching.decline_incoming_invitation(fighter, invitation.id, @ip) end
        ])

      case consistent!(invitation).status do
        :accepted ->
          assert {:ok, _} = accepted
          assert declined == {:error, :invitation_unavailable}
          assert active(coach) == 1

        :declined ->
          assert declined == :ok
          assert accepted == {:error, :invitation_unavailable}
          assert active(coach) == 0
      end
    end
  end

  test "accept by id racing the coach's cancel: exactly one outcome", %{users: users} do
    for _ <- 1..6 do
      {coach, fighter, invitation, _token, _to} = setup_pair(users)

      [accepted, cancelled] =
        concurrently([
          fn -> accept_id(fighter, invitation.id) end,
          fn -> Coaching.cancel_invitation(coach, invitation.id) end
        ])

      case consistent!(invitation).status do
        :accepted ->
          assert {:ok, _} = accepted
          assert cancelled == {:error, :conflict}
          assert active(coach) == 1

        :cancelled ->
          assert cancelled == :ok
          assert accepted == {:error, :invitation_unavailable}
          assert active(coach) == 0
      end
    end
  end

  test "accept by id racing a resend: the id is stable, one consistent outcome", %{users: users} do
    for _ <- 1..6 do
      {coach, fighter, invitation, _token, _to} = setup_pair(users)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -120)]
      )

      [accepted, resent] =
        concurrently([
          fn -> accept_id(fighter, invitation.id) end,
          fn -> Coaching.resend_invitation(coach, invitation.id, @ip) end
        ])

      # Either order ends accepted: a resend rotates the token, not the id.
      assert {:ok, _} = accepted
      assert consistent!(invitation).status == :accepted
      assert resent == {:error, :conflict} or match?({:ok, %Invitation{}}, resent)
      assert active(coach) == 1
    end
  end

  test "accept by id racing expiry: never accepted after expires_at", %{users: users} do
    for _ <- 1..6 do
      {coach, fighter, invitation, _token, _to} = setup_pair(users)
      past = DateTime.add(DateTime.utc_now(), -1)

      [accepted, {expired, _}] =
        concurrently([
          fn -> accept_id(fighter, invitation.id) end,
          fn ->
            Repo.update_all(
              from(i in Invitation, where: i.id == ^invitation.id and i.status == :pending),
              set: [expires_at: past]
            )
          end
        ])

      case consistent!(invitation).status do
        :accepted ->
          assert {:ok, _} = accepted
          assert expired == 0
          assert active(coach) == 1

        :pending ->
          assert expired == 1
          assert accepted == {:error, :invitation_unavailable}
          assert active(coach) == 0
      end
    end
  end

  test "a foreign fighter racing the recipient never wins", %{users: users} do
    {coach, fighter, invitation, _token, _to} = setup_pair(users)
    stranger = fighter!(users, address())

    results =
      concurrently(
        for who <- [stranger, fighter, stranger, stranger],
            do: fn -> accept_id(who, invitation.id) end
      )

    assert [{:error, :invitation_unavailable}, {:ok, _} | _] = results
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert active(coach) == 1

    assert Repo.get!(Relationship, consistent!(invitation).relationship_id).fighter_profile_id ==
             SimpleFit.Fighters.get_profile(fighter).id
  end
end
