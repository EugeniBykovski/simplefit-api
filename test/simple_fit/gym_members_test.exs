defmodule SimpleFit.GymMembersTest do
  @moduledoc """
  Gym members (SF-95): enrollment by join code, the staff's decisions,
  auto-approval, the lifecycle (leave, removal, re-enrollment), roster
  privacy and permission scopes, enrollment settings, the SF-90 checklist,
  SF-84 entry, audit events and the database guards.
  """

  use SimpleFit.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers

  alias SimpleFit.{Entry, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, EnrollmentSettings, Member, MemberSecrets}

  setup do
    owner = registered_as!(registered!("members"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, code: join_code!(owner, gym.id)}
  end

  defp events(gym_id, type),
    do: Repo.all(from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type))

  describe "joining by code" do
    test "creates a requested membership that grants nothing yet; a repeat returns it", ctx do
      user = email_user!(address("join"), "Marta Kowalska")

      assert {:ok, view, :created} = join(user, ctx.code)
      assert %{status: :requested, joined_via: :join_code, auto_approved: false} = view
      assert view.gym == %{gym_id: ctx.gym.id, name: "Simple Boxing Gym"}
      assert view.requested_at && is_nil(view.joined_at)

      assert {:ok, again, :existing} = join(user, ctx.code)
      assert again.gym_member_id == view.gym_member_id
      assert [%Member{status: :requested}] = member_rows(ctx.gym.id, user)

      # A membership is no staff membership: no workspace, no permission.
      assert {:error, :not_found} = Gyms.get_gym(user, ctx.gym.id)
      assert {:error, :not_found} = Gyms.list_members(user, ctx.gym.id, %{})
      assert [%AuditEvent{actor_user_id: actor}] = events(ctx.gym.id, :member_join_requested)
      assert actor == user.id
    end

    test "the code is forgiving to type and unknown, malformed or disabled codes are not_found",
         ctx do
      user = email_user!(address("typed"))
      typed = ctx.code |> String.downcase() |> String.replace("-", " ")
      assert {:ok, _view, :created} = join(user, typed)

      other = email_user!(address("other"))
      assert {:error, :not_found} = join(other, "ZZZZ-ZZZZ")
      assert {:error, :not_found} = join(other, "short")
      assert {:error, :not_found} = join(other, nil)
      assert {:error, :not_found} = join(other, String.duplicate("A", 40))

      {:ok, _} = Gyms.disable_join_code(ctx.owner, ctx.gym.id)
      assert {:error, :not_found} = join(other, ctx.code)
    end

    test "rotating the code stops the old one at once", ctx do
      new_code = join_code!(ctx.owner, ctx.gym.id)
      refute new_code == ctx.code
      user = email_user!(address("rotated"))
      assert {:error, :not_found} = join(user, ctx.code)
      assert {:ok, _view, :created} = join(user, new_code)
    end

    test "needs a completed account and nothing else (no Fighter or Coach profile)", ctx do
      {:ok, unregistered} = SimpleFit.Accounts.register_user(:email, address("unreg"))

      assert {:error, %Ecto.Changeset{} = changeset} = join(unregistered, ctx.code)
      assert {"must be completed first", _} = changeset.errors[:account_registration]
      assert member_rows(ctx.gym.id, unregistered) == []

      user = email_user!(address("nofighter"))
      assert {:ok, _view, :created} = join(user, ctx.code)

      refute Repo.exists?(
               from(f in "fighter_profiles", where: f.user_id == type(^user.id, :binary_id))
             )

      refute Repo.exists?(
               from(c in "coach_profiles", where: c.user_id == type(^user.id, :binary_id))
             )
    end

    test "an active member joining again is a conflict", ctx do
      {member, _view} = active_member!(ctx.owner, ctx.gym.id, ctx.code)
      assert {:error, {:conflict, %{gym_member: "already_active"}}} = join(member, ctx.code)
    end

    test "the public preview shows the gym and whether approval is needed", ctx do
      assert {:ok, %{gym: %{name: "Simple Boxing Gym"}, requires_approval: true}} =
               Gyms.preview_gym_join(ctx.code, client_ip())

      auto_approve!(ctx.owner, ctx.gym.id, true)

      assert {:ok, %{requires_approval: false}} = Gyms.preview_gym_join(ctx.code, client_ip())
      assert {:error, :not_found} = Gyms.preview_gym_join("ZZZZ-ZZZZ", client_ip())
    end

    test "joins and previews are rate limited per client and per user", ctx do
      ip = client_ip()

      for _ <- 1..20, do: Gyms.preview_gym_join("ZZZZ-ZZZZ", ip)
      assert {:error, {:rate_limited, _}} = Gyms.preview_gym_join(ctx.code, ip)

      user = email_user!(address("limited"))
      session = live_session!(user)
      for _ <- 1..10, do: Gyms.join_gym(user, session, "ZZZZ-ZZZZ", client_ip())
      assert {:error, {:rate_limited, _}} = Gyms.join_gym(user, session, ctx.code, client_ip())
    end
  end

  describe "auto-approval (D-G08)" do
    test "off by default; when the gym enables it a verified joiner is active at once", ctx do
      assert {:ok, %{auto_approve: false}} = Gyms.get_enrollment_settings(ctx.owner, ctx.gym.id)

      settings = auto_approve!(ctx.owner, ctx.gym.id, true)
      assert settings.auto_approve

      user = email_user!(address("auto"))
      assert {:ok, view, :created} = join(user, ctx.code)
      assert %{status: :active, auto_approved: true} = view
      assert view.joined_at

      assert [_] = events(ctx.gym.id, :member_join_auto_approved)

      assert [%AuditEvent{enabled: true, actor_user_id: owner_id}] =
               events(ctx.gym.id, :member_auto_approval_changed)

      assert owner_id == ctx.owner.id
    end

    test "never activates a user without a verified sign-in identity", ctx do
      auto_approve!(ctx.owner, ctx.gym.id, true)
      user = email_user!(address("noidentity"))
      Repo.delete_all(from(i in "identities", where: i.user_id == type(^user.id, :binary_id)))

      assert {:ok, %{status: :requested, auto_approved: false}, :created} = join(user, ctx.code)
    end

    test "the same value again changes nothing and records nothing; off is audited too", ctx do
      auto_approve!(ctx.owner, ctx.gym.id, false)
      assert events(ctx.gym.id, :member_auto_approval_changed) == []

      auto_approve!(ctx.owner, ctx.gym.id, true)
      auto_approve!(ctx.owner, ctx.gym.id, false)

      assert ctx.gym.id
             |> events(:member_auto_approval_changed)
             |> Enum.map(& &1.enabled)
             |> Enum.sort() == [false, true]
    end

    test "settings: only owner and managers change them; front desk reads the code; coach nothing",
         ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager)
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk)
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)

      assert {:ok, %{join_code: code, can_manage: false}} =
               Gyms.get_enrollment_settings(desk, ctx.gym.id)

      assert code == ctx.code
      assert {:error, :forbidden} = Gyms.rotate_join_code(desk, ctx.gym.id)

      assert {:error, :forbidden} =
               Gyms.update_enrollment_settings(desk, ctx.gym.id, %{"auto_approve" => true})

      assert {:error, :forbidden} = Gyms.get_enrollment_settings(coach, ctx.gym.id)

      assert {:ok, %{can_manage: true, join_code: rotated}} =
               Gyms.rotate_join_code(manager, ctx.gym.id)

      refute rotated == ctx.code

      assert {:error, %Ecto.Changeset{}} =
               Gyms.update_enrollment_settings(ctx.owner, ctx.gym.id, %{"auto_approve" => "maybe"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Gyms.update_enrollment_settings(ctx.owner, ctx.gym.id, %{
                 "auto_approve" => true,
                 "gym_id" => Ecto.UUID.generate()
               })

      assert changeset.errors[:auto_approve] == nil
    end

    test "a draft has no enrollment settings to change; outsiders get not_found", ctx do
      owner = registered!("draft-members")
      draft = draft_gym!(owner)

      assert {:error, {:conflict, %{setup_status: "draft"}}} =
               Gyms.rotate_join_code(owner, draft.id)

      outsider = registered!("outsider")
      assert {:error, :not_found} = Gyms.get_enrollment_settings(outsider, ctx.gym.id)
      assert {:error, :not_found} = Gyms.rotate_join_code(outsider, ctx.gym.id)
    end

    test "the code is stored only as a digest and an encrypted copy", ctx do
      settings = Repo.get!(EnrollmentSettings, ctx.gym.id)
      {:ok, canonical} = MemberSecrets.normalize_join_code(ctx.code)
      assert settings.join_code_digest == MemberSecrets.join_code_digest(canonical)
      refute settings.join_code_sealed =~ canonical
      refute inspect(settings) =~ canonical
      assert [%AuditEvent{}] = events(ctx.gym.id, :join_code_rotated)
    end
  end

  describe "staff decisions" do
    test "owner, manager and front desk approve or reject; coaches cannot", ctx do
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk)
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
      {_a, a} = requester!(ctx.code, "Anna Nowak")
      {_b, b} = requester!(ctx.code, "Bartek Zieliński")

      assert {:ok, %{entries: requests}} = Gyms.list_join_requests(desk, ctx.gym.id, %{})
      assert Enum.map(requests, & &1.name) == ["Anna N.", "Bartek Z."]
      assert {:error, :forbidden} = Gyms.list_join_requests(coach, ctx.gym.id, %{})
      assert {:error, :forbidden} = Gyms.approve_join_request(coach, ctx.gym.id, a.gym_member_id)

      assert {:ok, %{status: :active} = approved} =
               Gyms.approve_join_request(desk, ctx.gym.id, a.gym_member_id)

      assert approved.joined_at

      assert {:ok, %{status: :active}} =
               Gyms.approve_join_request(desk, ctx.gym.id, a.gym_member_id)

      assert {:ok, %{status: :rejected, responded_at: %DateTime{}}} =
               Gyms.reject_join_request(ctx.owner, ctx.gym.id, b.gym_member_id)

      assert {:ok, %{status: :rejected}} =
               Gyms.reject_join_request(ctx.owner, ctx.gym.id, b.gym_member_id)

      assert {:error, {:conflict, %{gym_member: "rejected"}}} =
               Gyms.approve_join_request(ctx.owner, ctx.gym.id, b.gym_member_id)

      assert {:error, {:conflict, %{gym_member: "active"}}} =
               Gyms.reject_join_request(ctx.owner, ctx.gym.id, a.gym_member_id)

      assert [%AuditEvent{actor_user_id: desk_id}] = events(ctx.gym.id, :member_join_approved)
      assert desk_id == desk.id
      assert [_] = events(ctx.gym.id, :member_join_rejected)
      assert {:ok, %{entries: []}} = Gyms.list_join_requests(ctx.owner, ctx.gym.id, %{})
    end

    test "another gym's member id and malformed ids are not_found", ctx do
      {_u, view} = requester!(ctx.code)
      other_owner = registered!("other-gym")
      other = completed_gym!(other_owner)

      assert {:error, :not_found} =
               Gyms.approve_join_request(other_owner, other.id, view.gym_member_id)

      assert {:error, :not_found} = Gyms.approve_join_request(ctx.owner, ctx.gym.id, "nope")
      assert {:error, :not_found} = Gyms.get_member(other_owner, other.id, view.gym_member_id)
    end

    test "removal: owner and managers end an active membership; front desk cannot", ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager)
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk)
      {_m, member} = active_member!(ctx.owner, ctx.gym.id, ctx.code)

      assert {:error, :forbidden} = Gyms.remove_member(desk, ctx.gym.id, member.gym_member_id)

      assert {:ok, %{status: :ended, ended_reason: :removed}} =
               Gyms.remove_member(manager, ctx.gym.id, member.gym_member_id)

      assert {:ok, %{status: :ended}} =
               Gyms.remove_member(manager, ctx.gym.id, member.gym_member_id)

      assert [%AuditEvent{reason: :removed}] = events(ctx.gym.id, :member_ended)

      {_r, request} = requester!(ctx.code, "Ola Nowak")

      assert {:error, {:conflict, %{gym_member: "requested"}}} =
               Gyms.remove_member(ctx.owner, ctx.gym.id, request.gym_member_id)
    end
  end

  describe "the member's own side" do
    test "cancel a request, leave, and re-enroll with history kept", ctx do
      user = email_user!(address("cycle"))
      session = live_session!(user)

      {:ok, first, :created} = Gyms.join_gym(user, session, ctx.code, client_ip())

      assert {:ok, %{status: :cancelled}} =
               Gyms.cancel_gym_join_request(user, session, first.gym_member_id)

      assert {:ok, %{status: :cancelled}} =
               Gyms.cancel_gym_join_request(user, session, first.gym_member_id)

      {:ok, second, :created} = Gyms.join_gym(user, session, ctx.code, client_ip())
      refute second.gym_member_id == first.gym_member_id
      {:ok, _} = Gyms.approve_join_request(ctx.owner, ctx.gym.id, second.gym_member_id)

      assert {:error, {:conflict, %{gym_member: "active"}}} =
               Gyms.cancel_gym_join_request(user, session, second.gym_member_id)

      assert {:ok, %{status: :ended, ended_reason: :left}} =
               Gyms.leave_gym_membership(user, session, second.gym_member_id)

      assert {:ok, %{status: :ended}} =
               Gyms.leave_gym_membership(user, session, second.gym_member_id)

      assert [%AuditEvent{reason: :left, actor_user_id: actor}] =
               events(ctx.gym.id, :member_ended)

      assert actor == user.id

      {:ok, third, :created} = Gyms.join_gym(user, session, ctx.code, client_ip())

      assert ctx.gym.id |> member_rows(user) |> Enum.map(& &1.status) ==
               [:cancelled, :ended, :requested]

      assert {:ok, %{entries: mine}} = Gyms.list_my_gym_memberships(user, %{})

      assert Enum.map(mine, & &1.gym_member_id) == [
               third.gym_member_id,
               second.gym_member_id,
               first.gym_member_id
             ]

      assert {:ok, %{entries: [_]}} = Gyms.list_my_gym_memberships(user, %{"status" => "ended"})

      assert {:error, %Ecto.Changeset{}} =
               Gyms.list_my_gym_memberships(user, %{"status" => "bogus"})
    end

    test "nobody touches someone else's membership", ctx do
      {_owner_of, view} = requester!(ctx.code)
      intruder = email_user!(address("intruder"))
      session = live_session!(intruder)

      assert {:error, :not_found} =
               Gyms.cancel_gym_join_request(intruder, session, view.gym_member_id)

      assert {:error, :not_found} =
               Gyms.leave_gym_membership(intruder, session, view.gym_member_id)

      assert {:error, :not_found} = Gyms.get_my_gym_membership(intruder, view.gym_member_id)
    end

    test "a revoked session cannot join", ctx do
      user = email_user!(address("revoked"))
      {:ok, credentials} = SimpleFit.Accounts.create_session(user)
      :ok = SimpleFit.Accounts.revoke_session({:access, credentials.access_token})

      assert {:error, :session_revoked} =
               Gyms.join_gym(user, credentials.session, ctx.code, client_ip())

      assert member_rows(ctx.gym.id, user) == []
    end

    test "leaving as a member leaves a staff membership at the gym untouched", ctx do
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
      session = live_session!(coach)
      {:ok, view, :created} = Gyms.join_gym(coach, session, ctx.code, client_ip())
      {:ok, _} = Gyms.approve_join_request(ctx.owner, ctx.gym.id, view.gym_member_id)
      {:ok, _} = Gyms.leave_gym_membership(coach, session, view.gym_member_id)

      assert [_active] = active_memberships(ctx.gym.id, coach)
      assert {:ok, %{viewer: %{role: :coach}}} = Gyms.get_gym(coach, ctx.gym.id)
    end
  end

  describe "roster privacy and scopes" do
    test "short names and gym facts only; coaches are refused", ctx do
      {member, _} = active_member!(ctx.owner, ctx.gym.id, ctx.code, "Marta Kowalska")
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk)

      assert {:ok, %{entries: [entry]}} = Gyms.list_members(desk, ctx.gym.id, %{})
      assert entry.name == "Marta K."

      assert Map.keys(entry) |> Enum.sort() ==
               ~w(auto_approved ended_at ended_reason gym_member_id joined_at joined_via name requested_at responded_at status)a

      [email] = SimpleFit.Accounts.verified_email_addresses(member)
      refute inspect(entry) =~ email
      refute inspect(entry) =~ member.id

      assert {:error, :forbidden} = Gyms.list_members(coach, ctx.gym.id, %{})
      assert {:error, :forbidden} = Gyms.get_member(coach, ctx.gym.id, entry.gym_member_id)
      assert {:error, :not_found} = Gyms.list_members(registered!("x"), ctx.gym.id, %{})
    end

    test "active and ended lists page with cursors", ctx do
      for name <- ["Anna Nowak", "Bartek Zieliński", "Celina Wójcik"],
          do: active_member!(ctx.owner, ctx.gym.id, ctx.code, name)

      {:ok, page1} = Gyms.list_members(ctx.owner, ctx.gym.id, %{"limit" => "2"})
      assert length(page1.entries) == 2 and page1.next_cursor

      {:ok, page2} =
        Gyms.list_members(ctx.owner, ctx.gym.id, %{"limit" => "2", "cursor" => page1.next_cursor})

      assert [%{name: "Celina W."}] = page2.entries
      assert page2.next_cursor == nil

      [first | _] = page1.entries
      {:ok, _} = Gyms.remove_member(ctx.owner, ctx.gym.id, first.gym_member_id)

      assert {:ok, %{entries: [%{status: :ended}]}} =
               Gyms.list_members(ctx.owner, ctx.gym.id, %{"status" => "ended"})

      assert {:error, %Ecto.Changeset{}} =
               Gyms.list_members(ctx.owner, ctx.gym.id, %{"cursor" => "junk"})

      assert {:error, %Ecto.Changeset{}} =
               Gyms.list_members(ctx.owner, ctx.gym.id, %{"status" => "requested"})
    end
  end

  describe "SF-90 checklist and SF-84 entry" do
    test "invite_members: available, then completed once someone became active (and stays)",
         ctx do
      status = fn ->
        {:ok, state} = Gyms.get_first_run(ctx.owner, ctx.gym.id)
        Enum.find(state.checklist, &(&1.key == :invite_members)).status
      end

      assert status.() == :available
      {_u, request} = requester!(ctx.code)
      assert status.() == :available
      {:ok, _} = Gyms.approve_join_request(ctx.owner, ctx.gym.id, request.gym_member_id)
      assert status.() == :completed
      {:ok, _} = Gyms.remove_member(ctx.owner, ctx.gym.id, request.gym_member_id)
      assert status.() == :completed
    end

    test "a member gets no GYM_WORKSPACE context", ctx do
      {member, _} = active_member!(ctx.owner, ctx.gym.id, ctx.code)
      assert %{total: 0} = Gyms.workspace_overview(member, 10)
      {:ok, entry} = Entry.resolve(member)
      refute inspect(entry) =~ "GYM_WORKSPACE"
      refute inspect(entry) =~ ctx.gym.id
    end
  end

  describe "database guards" do
    test "rows are never deleted, final rows never change, illegal moves are refused", ctx do
      {_m, member} = active_member!(ctx.owner, ctx.gym.id, ctx.code)
      id = member.gym_member_id

      assert_raise Postgrex.Error, ~r/gym memberships are never deleted/, fn ->
        Repo.delete_all(from(m in Member, where: m.id == ^id))
      end

      assert_raise Postgrex.Error, ~r/transition active -> requested/, fn ->
        Repo.update_all(from(m in Member, where: m.id == ^id),
          set: [status: :requested, activated_at: nil]
        )
      end

      {:ok, _} = Gyms.remove_member(ctx.owner, ctx.gym.id, id)

      assert_raise Postgrex.Error, ~r/final gym membership is immutable/, fn ->
        Repo.update_all(from(m in Member, where: m.id == ^id), set: [ended_reason: :left])
      end
    end

    test "one current membership per gym and user; members only at completed gyms", ctx do
      {user, _} = requester!(ctx.code)
      now = DateTime.utc_now()

      row = fn gym_id ->
        %{
          id: Ecto.UUID.generate(),
          gym_id: gym_id,
          user_id: user.id,
          status: :requested,
          joined_via: :join_code,
          requested_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

      assert_raise Postgrex.Error, ~r/gym_members_current_index/, fn ->
        Repo.insert_all(Member, [row.(ctx.gym.id)])
      end

      draft = draft_gym!(registered!("draft-guard"))

      assert_raise Postgrex.Error, ~r/completed gym/, fn ->
        Repo.insert_all(Member, [row.(draft.id)])
      end

      assert_raise Postgrex.Error, ~r/starts requested/, fn ->
        Repo.insert_all(Member, [
          %{row.(ctx.gym.id) | status: :active}
          |> Map.put(:activated_at, now)
          |> Map.put(:user_id, registered!("y").id)
        ])
      end
    end

    test "a user with a current membership cannot be deleted; a final one keeps its history",
         ctx do
      {user, view} = requester!(ctx.code)

      assert_raise Postgrex.Error, ~r/user_present/, fn ->
        Repo.delete_all(from(u in SimpleFit.Accounts.User, where: u.id == ^user.id))
      end

      {:ok, _} = Gyms.reject_join_request(ctx.owner, ctx.gym.id, view.gym_member_id)
      Repo.delete_all(from(u in SimpleFit.Accounts.User, where: u.id == ^user.id))
      assert %Member{user_id: nil, status: :rejected} = stored_member(view.gym_member_id)
    end
  end
end
