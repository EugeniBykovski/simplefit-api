defmodule SimpleFit.GymMembersRaceTest do
  @moduledoc """
  Gym members and member invitations under true concurrency and real
  commits (SF-95), on separate connections outside the SQL sandbox: the gym
  row locks, the settings and member row locks, the partial unique index on
  current memberships and the guard triggers are exercised for real. Every
  test checks the final database state. Rows are committed: every test
  removes what it created (gym memberships through the purge switch).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias SimpleFit.Accounts.User
  alias SimpleFit.{Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, Gym, Member, MemberInvitation, StaffMembership}

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

      purge_gyms!(gym_ids)
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Repo.delete_all(from(j in Oban.Job, where: j.id > ^first_job))
      reset_limits()
      Agent.stop(users)
      Sandbox.mode(Repo, :manual)
    end)

    owner = track(users, registered_as!(registered!("mrace-owner"), "Yauheni Bykovski"))
    gym = completed_gym!(owner)
    %{users: users, owner: owner, gym: gym, code: join_code!(owner, gym.id)}
  end

  defp track(users, user) do
    Agent.update(users, &[user.id | &1])
    user
  end

  defp user(users, email \\ address("mrace")), do: {track(users, email_user!(email)), email}

  defp reset_limits do
    Repo.delete_all("auth_rate_limits")
    Repo.delete_all("rate_limit_events")
  end

  defp concurrently(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)

  defp events(gym_id, type),
    do: Repo.all(from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type))

  test "12 simultaneous joins by one user create one request", ctx do
    {user, _} = user(ctx.users)
    session = live_session!(user)

    results =
      concurrently(
        for _ <- 1..12, do: fn -> Gyms.join_gym(user, session, ctx.code, client_ip()) end
      )

    ids = for {:ok, view, _} <- results, uniq: true, do: view.gym_member_id
    assert length(ids) == 1
    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert [%Member{status: :requested}] = member_rows(ctx.gym.id, user)
    assert [_] = events(ctx.gym.id, :member_join_requested)
  end

  test "approve, reject and cancel racing on one request: one outcome, one event", ctx do
    for _round <- 1..6 do
      {user, _} = user(ctx.users)
      session = live_session!(user)
      {:ok, request, :created} = Gyms.join_gym(user, session, ctx.code, client_ip())
      id = request.gym_member_id

      results =
        concurrently([
          fn -> Gyms.approve_join_request(ctx.owner, ctx.gym.id, id) end,
          fn -> Gyms.reject_join_request(ctx.owner, ctx.gym.id, id) end,
          fn -> Gyms.cancel_gym_join_request(user, session, id) end
        ])

      final = stored_member(id)
      assert final.status in [:active, :rejected, :cancelled]
      assert Enum.count(results, &match?({:ok, %{status: s}} when s == final.status, &1)) == 1
      assert Enum.count(results, &match?({:error, {:conflict, _}}, &1)) == 2

      decided =
        Repo.aggregate(
          from(e in AuditEvent,
            where:
              e.gym_member_id == ^id and
                e.event_type in [
                  :member_join_approved,
                  :member_join_rejected,
                  :member_join_cancelled
                ]
          ),
          :count
        )

      assert decided == 1
    end
  end

  test "12 simultaneous acceptances of one invitation create one membership", ctx do
    {user, email} = user(ctx.users)
    invitation = invite_member!(ctx.owner, ctx.gym.id, email)
    token = member_token_for(email)

    results =
      concurrently(
        for i <- 1..12 do
          locator = if rem(i, 2) == 0, do: {:token, token}, else: {:id, invitation.invitation_id}
          fn -> Gyms.accept_member_invitation(user, live_session!(user), locator, client_ip()) end
        end
      )

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:ok, %{outcome: :accepted}}, &1)) == 1
    assert [%Member{status: :active, joined_via: :invitation}] = member_rows(ctx.gym.id, user)

    assert %MemberInvitation{status: :accepted} =
             Repo.get!(MemberInvitation, invitation.invitation_id)

    assert [_] = events(ctx.gym.id, :member_invitation_accepted)
  end

  test "a join and an invitation acceptance by the same user end with one active membership",
       ctx do
    for _round <- 1..6 do
      {user, email} = user(ctx.users)
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)

      concurrently([
        fn -> Gyms.join_gym(user, live_session!(user), ctx.code, client_ip()) end,
        fn ->
          Gyms.accept_member_invitation(
            user,
            live_session!(user),
            {:id, invitation.invitation_id},
            client_ip()
          )
        end
      ])

      rows = member_rows(ctx.gym.id, user)
      assert [%Member{status: :active}] = rows

      assert %MemberInvitation{status: :accepted} =
               Repo.get!(MemberInvitation, invitation.invitation_id)
    end
  end

  test "joins racing an auto-approval switch: every result matches its own audit trail", ctx do
    joiners = for _ <- 1..10, do: elem(user(ctx.users), 0)

    concurrently(
      [fn -> auto_approve!(ctx.owner, ctx.gym.id, true) end] ++
        for(u <- joiners, do: fn -> join(u, ctx.code) end)
    )

    rows = Repo.all(from(m in Member, where: m.gym_id == ^ctx.gym.id))
    assert length(rows) == 10

    for row <- rows do
      assert row.auto_approved == (row.status == :active)
    end

    assert length(events(ctx.gym.id, :member_join_auto_approved)) ==
             Enum.count(rows, & &1.auto_approved)

    assert length(events(ctx.gym.id, :member_join_requested)) == 10
  end

  test "joins racing a code rotation: a stale code never creates a membership after it", ctx do
    joiners = for _ <- 1..10, do: elem(user(ctx.users), 0)

    results =
      concurrently(
        [fn -> Gyms.rotate_join_code(ctx.owner, ctx.gym.id) end] ++
          for(u <- joiners, do: fn -> join(u, ctx.code) end)
      )

    [{:ok, _rotated} | joins] = results
    created = Enum.count(joins, &match?({:ok, _, :created}, &1))
    assert created + Enum.count(joins, &(&1 == {:error, :not_found})) == 10
    assert Repo.aggregate(from(m in Member, where: m.gym_id == ^ctx.gym.id), :count) == created
    assert {:error, :not_found} = join(elem(user(ctx.users), 0), ctx.code)
  end

  test "leave and removal racing on one membership: one end, one event", ctx do
    for _round <- 1..6 do
      {user, _} = user(ctx.users)
      session = live_session!(user)
      {:ok, request, :created} = Gyms.join_gym(user, session, ctx.code, client_ip())
      {:ok, _} = Gyms.approve_join_request(ctx.owner, ctx.gym.id, request.gym_member_id)

      concurrently([
        fn -> Gyms.leave_gym_membership(user, session, request.gym_member_id) end,
        fn -> Gyms.remove_member(ctx.owner, ctx.gym.id, request.gym_member_id) end
      ])

      assert %Member{status: :ended, ended_reason: reason} = stored_member(request.gym_member_id)
      assert reason in [:left, :removed]

      assert Repo.aggregate(
               from(e in AuditEvent,
                 where:
                   e.gym_member_id == ^request.gym_member_id and e.event_type == :member_ended
               ),
               :count
             ) == 1
    end
  end
end
