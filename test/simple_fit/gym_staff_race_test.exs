defmodule SimpleFit.GymStaffRaceTest do
  @moduledoc """
  Gym staff invitations and memberships under true concurrency and real
  commits (SF-93), on separate database connections outside the SQL sandbox:
  the gym row lock, the invitation and session row locks, the partial unique
  indexes, the invitation guard triggers and the commit-time "exactly one
  active owner" trigger are all exercised for real. Every test checks the
  final database state, not only the answers. Rows are committed: every test
  removes the gyms, audit events, email jobs and users it created.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.{Accounts, Entry, Gyms, Repo}
  alias SimpleFit.Accounts.User
  alias SimpleFit.Gyms.{AuditEvent, Gym, StaffInvitation, StaffMembership}

  @rounds 6

  setup do
    Sandbox.mode(Repo, :auto)
    reset_limits()
    {:ok, users} = Agent.start(fn -> [] end)
    first_job = Repo.one(from(j in Oban.Job, select: max(j.id))) || 0

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      ids = Agent.get(users, & &1)

      gym_ids =
        Repo.all(
          from(g in Gym,
            left_join: m in StaffMembership,
            on: m.gym_id == g.id,
            where: g.created_by_user_id in ^ids or m.user_id in ^ids,
            distinct: true,
            select: g.id
          )
        )

      Repo.delete_all(from(e in AuditEvent, where: e.gym_id in ^gym_ids))
      Repo.delete_all(from(g in Gym, where: g.id in ^gym_ids))
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all(from(j in Oban.Job, where: j.id > ^first_job))
      reset_limits()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    owner = track(users, registered_as!(registered!("race-owner"), "Yauheni Bykovski"))
    %{users: users, owner: owner, gym: completed_gym!(owner)}
  end

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp email_user(users, email \\ address("race")), do: {track(users, email_user!(email)), email}

  defp reset_limits do
    Repo.delete_all("auth_rate_limits")
    Repo.delete_all("rate_limit_events")
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

  defp accept(user, locator, session \\ nil),
    do: Gyms.accept_staff_invitation(user, session || live_session!(user), locator, client_ip())

  defp events(gym_id, type),
    do: Repo.all(from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type))

  defp invitation(id), do: Repo.get!(StaffInvitation, id)

  test "12 simultaneous acceptances create one membership and one acceptance", ctx do
    {user, email} = email_user(ctx.users)
    %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
    token = staff_token_for(email)

    results =
      concurrently(
        for i <- 1..12 do
          locator = if rem(i, 2) == 0, do: {:id, id}, else: {:token, token}
          fn -> accept(user, locator) end
        end
      )

    assert Enum.count(results, &match?({:ok, %{outcome: :accepted}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{outcome: :already_accepted}}, &1)) == 11

    assert results
           |> Enum.map(fn {:ok, r} -> r.staff_membership_id end)
           |> Enum.uniq()
           |> length() == 1

    assert [%StaffMembership{role: :coach, id: membership_id}] =
             active_memberships(ctx.gym.id, user)

    assert %{status: :accepted, staff_membership_id: ^membership_id} = invitation(id)
    assert [_] = events(ctx.gym.id, :staff_invitation_accepted)
  end

  test "two accounts race for one invitation: only the verified recipient joins", ctx do
    {recipient, email} = email_user(ctx.users)
    {intruder, _} = email_user(ctx.users)
    %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :manager)
    token = staff_token_for(email)

    results =
      concurrently(
        for _ <- 1..4,
            user <- [recipient, intruder],
            do: fn -> {user.id, accept(user, {:token, token})} end
      )

    {mine, theirs} = Enum.split_with(results, fn {user_id, _} -> user_id == recipient.id end)

    assert Enum.all?(mine, fn {_, result} ->
             match?(
               {:ok, %{outcome: outcome}} when outcome in [:accepted, :already_accepted],
               result
             )
           end)

    assert Enum.all?(theirs, fn {_, result} ->
             result in [
               {:error, :invitation_recipient_mismatch},
               {:error, :invitation_unavailable}
             ]
           end)

    assert [_] = active_memberships(ctx.gym.id, recipient)
    assert active_memberships(ctx.gym.id, intruder) == []
    assert invitation(id).status == :accepted
  end

  test "accept racing cancel: one consistent outcome every time", ctx do
    for _ <- 1..@rounds do
      {user, email} = email_user(ctx.users)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)

      [accepted, cancelled] =
        concurrently([
          fn -> accept(user, {:id, id}) end,
          fn -> Gyms.cancel_staff_invitation(ctx.owner, ctx.gym.id, id) end
        ])

      case invitation(id) do
        %{status: :accepted} ->
          assert {:ok, %{outcome: :accepted}} = accepted
          assert cancelled == {:error, {:conflict, %{staff_invitation: "accepted"}}}
          assert [_] = active_memberships(ctx.gym.id, user)

        %{status: :cancelled} ->
          assert {:ok, %{status: :cancelled}} = cancelled
          assert accepted == {:error, :invitation_unavailable}
          assert active_memberships(ctx.gym.id, user) == []
      end
    end
  end

  test "accept racing decline: exactly one answer is kept", ctx do
    for _ <- 1..@rounds do
      {user, email} = email_user(ctx.users)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :front_desk)

      [accepted, declined] =
        concurrently([
          fn -> accept(user, {:id, id}) end,
          fn -> Gyms.decline_staff_invitation(user, {:id, id}, client_ip()) end
        ])

      case invitation(id) do
        %{status: :accepted} ->
          assert {:ok, _} = accepted
          assert declined == {:error, :invitation_unavailable}
          assert [_] = active_memberships(ctx.gym.id, user)

        %{status: :declined} ->
          assert {:ok, %{status: :declined}} = declined
          assert accepted == {:error, :invitation_unavailable}
          assert active_memberships(ctx.gym.id, user) == []
      end
    end
  end

  test "accept racing the removal of the inviter: accepted first, or cancelled with the inviter",
       ctx do
    for _ <- 1..@rounds do
      {manager, manager_email} = email_user(ctx.users)
      %{invitation_id: mid} = invite!(ctx.owner, ctx.gym.id, manager_email, :manager)
      %{staff_membership_id: manager_id} = accept!(manager, mid)
      {user, email} = email_user(ctx.users)
      %{invitation_id: id} = invite!(manager, ctx.gym.id, email, :coach)

      [accepted, removed] =
        concurrently([
          fn -> accept(user, {:id, id}) end,
          fn -> Gyms.end_staff_membership(ctx.owner, ctx.gym.id, manager_id) end
        ])

      assert {:ok, %{status: :ended}} = removed

      case invitation(id) do
        %{status: :accepted} ->
          assert {:ok, %{outcome: :accepted}} = accepted
          assert [_] = active_memberships(ctx.gym.id, user)

        %{status: :cancelled} ->
          assert accepted == {:error, :invitation_unavailable}
          assert active_memberships(ctx.gym.id, user) == []
      end
    end
  end

  test "two administrators invite the same address at once: one invitation, one email", ctx do
    {manager, manager_email} = email_user(ctx.users)
    accept!(manager, invite!(ctx.owner, ctx.gym.id, manager_email, :manager).invitation_id)
    email = address("same")

    results =
      concurrently(
        for user <- List.duplicate(ctx.owner, 4) ++ List.duplicate(manager, 4) do
          fn ->
            Gyms.create_staff_invitation(
              user,
              ctx.gym.id,
              %{"email" => email, "role" => "coach"},
              client_ip()
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :existing}, &1)) == 7

    assert results |> Enum.map(fn {:ok, v, _} -> v.invitation_id end) |> Enum.uniq() |> length() ==
             1

    assert length(SimpleFit.EmailAuthHelpers.emails_to(email)) == 1

    assert Repo.aggregate(
             from(i in StaffInvitation, where: i.gym_id == ^ctx.gym.id and i.status == :pending),
             :count
           ) == 1
  end

  test "concurrent invitations of one address to different roles: one pending invitation", ctx do
    email = address("roles")

    results =
      concurrently(
        for role <- ~w(manager coach front_desk manager coach front_desk) do
          fn ->
            Gyms.create_staff_invitation(
              ctx.owner,
              ctx.gym.id,
              %{"email" => email, "role" => role},
              client_ip()
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1

    assert Enum.all?(results, fn
             {:ok, _, _} -> true
             {:error, {:conflict, %{staff_invitation: "pending_other_role"}}} -> true
             _ -> false
           end)

    assert Repo.aggregate(from(i in StaffInvitation, where: i.gym_id == ^ctx.gym.id), :count) == 1
  end

  test "a role change racing a removal of the same member ends consistently", ctx do
    for _ <- 1..@rounds do
      {coach, email} = email_user(ctx.users)

      %{staff_membership_id: id} =
        accept!(coach, invite!(ctx.owner, ctx.gym.id, email, :coach).invitation_id)

      [changed, removed] =
        concurrently([
          fn -> Gyms.change_staff_role(ctx.owner, ctx.gym.id, id, %{"role" => "front_desk"}) end,
          fn -> Gyms.end_staff_membership(ctx.owner, ctx.gym.id, id) end
        ])

      assert {:ok, %{status: :ended}} = removed
      assert changed in [{:error, :not_found}] or match?({:ok, %{role: :front_desk}}, changed)

      ended = Repo.get!(StaffMembership, id)
      assert ended.status == :ended
      expected_role = if match?({:ok, _}, changed), do: :front_desk, else: :coach
      assert ended.role == expected_role
      assert active_memberships(ctx.gym.id, coach) == []
    end
  end

  test "concurrent attempts on the owner never leave the gym without exactly one owner", ctx do
    {manager, email} = email_user(ctx.users)
    accept!(manager, invite!(ctx.owner, ctx.gym.id, email, :manager).invitation_id)
    [owner_row] = active_owners(ctx.gym.id)

    results =
      concurrently(
        for _ <- 1..3 do
          [
            fn -> Gyms.end_staff_membership(ctx.owner, ctx.gym.id, owner_row.id) end,
            fn -> Gyms.end_staff_membership(manager, ctx.gym.id, owner_row.id) end,
            fn ->
              Gyms.change_staff_role(ctx.owner, ctx.gym.id, owner_row.id, %{"role" => "manager"})
            end,
            fn ->
              Gyms.change_staff_role(manager, ctx.gym.id, owner_row.id, %{"role" => "coach"})
            end
          ]
        end
        |> List.flatten()
      )

    assert Enum.all?(results, &match?({:error, _}, &1))
    assert [%{id: id}] = active_owners(ctx.gym.id)
    assert id == owner_row.id
  end

  test "removal racing the member's entry context choice: no stale gym context survives", ctx do
    for _ <- 1..@rounds do
      {coach, email} = email_user(ctx.users)

      %{staff_membership_id: id} =
        accept!(coach, invite!(ctx.owner, ctx.gym.id, email, :coach).invitation_id)

      [choice, removed] =
        concurrently([
          fn ->
            Entry.record_context_choice(coach, %{"context" => "gym", "gym_id" => ctx.gym.id})
          end,
          fn -> Gyms.end_staff_membership(ctx.owner, ctx.gym.id, id) end
        ])

      assert {:ok, _} = removed
      assert match?({:ok, _}, choice) or match?({:error, _}, choice)

      {:ok, entry} = Entry.resolve(coach)
      refute Enum.any?(entry.gym_workspaces, &(&1.gym_id == ctx.gym.id))
      assert entry.gym_id != ctx.gym.id
      assert Gyms.get_gym(coach, ctx.gym.id) == {:error, :not_found}
    end
  end

  test "a logout racing an acceptance: accepted on a live session, or refused after it", ctx do
    for _ <- 1..@rounds do
      {user, email} = email_user(ctx.users)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      {:ok, credentials} = Accounts.create_session(user)

      [accepted, :ok] =
        concurrently([
          fn -> accept(user, {:id, id}, credentials.session) end,
          fn -> Accounts.revoke_session({:access, credentials.access_token}) end
        ])

      case accepted do
        {:ok, %{outcome: :accepted}} ->
          assert [_] = active_memberships(ctx.gym.id, user)
          assert invitation(id).status == :accepted

        {:error, :session_revoked} ->
          assert active_memberships(ctx.gym.id, user) == []
          assert invitation(id).status == :pending
      end
    end
  end

  test "one coach accepts invitations of two gyms at once: two independent memberships", ctx do
    {coach, email} = email_user(ctx.users)
    other_owner = track(ctx.users, registered!("race-other"))
    other = completed_gym!(other_owner)
    %{invitation_id: a} = invite!(ctx.owner, ctx.gym.id, email, :coach)
    %{invitation_id: b} = invite!(other_owner, other.id, email, :manager)

    results = concurrently([fn -> accept(coach, {:id, a}) end, fn -> accept(coach, {:id, b}) end])

    assert Enum.all?(results, &match?({:ok, %{outcome: :accepted}}, &1))
    assert [%{role: :coach}] = active_memberships(ctx.gym.id, coach)
    assert [%{role: :manager}] = active_memberships(other.id, coach)
  end
end
