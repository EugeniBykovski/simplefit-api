defmodule SimpleFit.CoachingInvitationsRaceTest do
  @moduledoc """
  Coach invitations under true concurrency, on separate database
  connections outside the SQL sandbox (SF-57): the outcome of an invitation,
  the accepted disclosure and the relationship it activates always commit
  together or not at all. Rows are committed, so every test removes the
  users it created (profiles, relationships and invitations cascade).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Coaches, Coaching, Repo}
  alias SimpleFit.Coaching.{Invitation, Relationship}

  @ip "198.51.100.9"

  setup do
    Sandbox.mode(Repo, :auto)
    configure_sharing()
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

  defp address, do: "race-#{System.unique_integer([:positive])}@example.com"
  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(15_000)

  defp accept(user, token),
    do:
      Coaching.accept_invitation(
        user,
        %{"token" => token, "disclosure_version" => version()},
        @ip
      )

  defp coach!(users, name \\ "Coach Marek"), do: inviting_coach!(name) |> track(users)
  defp fighter!(users, to), do: email_fighter!(to) |> track(users)

  defp active(coach) do
    profile = Coaches.get_profile(coach).id

    Repo.aggregate(
      from(r in Relationship, where: r.coach_profile_id == ^profile and r.status == :active),
      :count
    )
  end

  # Invitation outcome, consent evidence and relationship always agree.
  # `ended_ok`: the relationship may have been ended after the acceptance
  # committed (a concurrent end serialized after it).
  defp consistent!(%Invitation{id: id}, ended_ok \\ false) do
    invitation = Repo.get!(Invitation, id)

    case invitation.status do
      :accepted ->
        assert invitation.accepted_disclosure_version == version()
        relationship = Repo.get!(Relationship, invitation.relationship_id)
        assert relationship.status == :active or ended_ok

      _other ->
        assert invitation.accepted_disclosure_version == nil
        assert invitation.relationship_id == nil
    end

    invitation
  end

  test "simultaneous acceptances with one token: one relationship, the rest unavailable", %{
    users: users
  } do
    coach = coach!(users)
    to = address()
    {invitation, token} = invite!(coach, to)
    fighter = fighter!(users, to)

    results = concurrently(for _ <- 1..8, do: fn -> accept(fighter, token) end)

    assert Enum.count(results, &match?({:ok, %{outcome: :created}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invitation_unavailable})) == 7
    assert active(coach) == 1
    assert consistent!(invitation).status == :accepted
  end

  test "accept racing decline: exactly one outcome, consistent", %{users: users} do
    for _ <- 1..6 do
      coach = coach!(users)
      to = address()
      {invitation, token} = invite!(coach, to)
      fighter = fighter!(users, to)

      [accepted, declined] =
        concurrently([
          fn -> accept(fighter, token) end,
          fn -> Coaching.decline_invitation(fighter, %{"token" => token}, @ip) end
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

  test "accept racing the coach's cancel: exactly one outcome, consistent", %{users: users} do
    for _ <- 1..6 do
      coach = coach!(users)
      to = address()
      {invitation, token} = invite!(coach, to)
      fighter = fighter!(users, to)

      [accepted, cancelled] =
        concurrently([
          fn -> accept(fighter, token) end,
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

  test "accept with the old token racing a resend never accepts a rotated token", %{
    users: users
  } do
    for _ <- 1..6 do
      coach = coach!(users)
      to = address()
      {invitation, old} = invite!(coach, to)
      fighter = fighter!(users, to)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -120)]
      )

      [accepted, resent] =
        concurrently([
          fn -> accept(fighter, old) end,
          fn -> Coaching.resend_invitation(coach, invitation.id, @ip) end
        ])

      case consistent!(invitation).status do
        # The acceptance locked first: the resend finds it accepted.
        :accepted ->
          assert {:ok, _} = accepted
          assert resent == {:error, :conflict}

        # The resend rotated first: the old token no longer matches.
        :pending ->
          assert {:ok, _} = resent
          assert accepted == {:error, :invitation_unavailable}
          assert {:ok, _} = accept(fighter, last_token_to(to))
      end

      assert active(coach) <= 1
    end
  end

  test "simultaneous invitations of one address create one invitation and one email", %{
    users: users
  } do
    coach = coach!(users)
    to = address()

    # Within the per-recipient limit (3 a day), which counts every request.
    results =
      concurrently(for _ <- 1..3, do: fn -> Coaching.invite(coach, %{"email" => to}, @ip) end)

    assert Enum.all?(results, &match?({:ok, %Invitation{}, _}, &1))
    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert results |> Enum.map(fn {:ok, i, _} -> i.id end) |> Enum.uniq() |> length() == 1
    assert length(emails_to(to)) == 1
  end

  test "simultaneous resends rotate once and send one email", %{users: users} do
    coach = coach!(users)
    to = address()
    {invitation, _} = invite!(coach, to)

    Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
      set: [last_sent_at: DateTime.add(DateTime.utc_now(), -120)]
    )

    results =
      concurrently(
        for _ <- 1..5, do: fn -> Coaching.resend_invitation(coach, invitation.id, @ip) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results -- Enum.filter(results, &match?({:ok, _}, &1)),
             &match?({:error, {:rate_limited, _}}, &1)
           )

    assert Repo.get!(Invitation, invitation.id).send_count == 2
    assert length(emails_to(to)) == 2
  end

  test "several coaches' invitations accepted at once by one fighter", %{users: users} do
    to = address()
    coaches = for i <- 1..4, do: coach!(users, "Coach #{i}")
    # The per-recipient limit (3 a day) is reset between coaches.
    tokens =
      for coach <- coaches do
        reset_rate_limits()
        coach |> invite!(to) |> elem(1)
      end

    fighter = fighter!(users, to)

    results = concurrently(for token <- tokens, do: fn -> accept(fighter, token) end)

    assert Enum.all?(results, &match?({:ok, %{outcome: :created}}, &1))
    assert {:ok, %{entries: entries}} = Coaching.list_fighter_relationships(fighter, %{})
    assert length(entries) == 4
  end

  test "ending a relationship while a new invitation is accepted leaves at most one active", %{
    users: users
  } do
    for _ <- 1..6 do
      coach = coach!(users)
      to = address()
      fighter = fighter!(users, to)
      existing = activate!(coach, fighter)
      {invitation, token} = invite!(coach, to)

      [ended, accepted] =
        concurrently([
          fn -> Coaching.end_relationship(fighter, :fighter, existing.id) end,
          fn -> accept(fighter, token) end
        ])

      assert ended == :ok
      assert {:ok, %{relationship_id: id, outcome: outcome}} = accepted
      assert Repo.get!(Relationship, existing.id).status == :ended
      assert active(coach) <= 1
      assert consistent!(invitation, true).relationship_id == id

      # Resolved to the old (now ended) relationship, or a new active one.
      if outcome == :already_connected,
        do: assert(id == existing.id),
        else: refute(id == existing.id)
    end
  end

  test "a failed activation rolls the whole acceptance back", %{users: users} do
    coach = coach!(users)
    to = address()
    {invitation, token} = invite!(coach, to)
    fighter = fighter!(users, to)

    # Sharing switched off between preview and acceptance: activation refuses
    # inside the transaction that already locked the invitation.
    set_sharing(enabled: false)
    assert {:error, :not_found} = accept(fighter, token)
    set_sharing([])

    assert consistent!(invitation).status == :pending
    assert active(coach) == 0
    assert {:ok, _} = accept(fighter, token)
  end
end
