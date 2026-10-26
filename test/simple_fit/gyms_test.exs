defmodule SimpleFit.GymsTest do
  @moduledoc """
  The Gyms context (SF-83; ADR 0026): creation and owner bootstrap,
  idempotency, the open-draft rule, abuse limits, the fixed role matrix,
  tenant isolation, revocation, ownership transfer rules, audit events and
  the account-deletion guard. Concurrency and commit-time invariants are in
  `SimpleFit.GymsRaceTest`.
  """

  use SimpleFit.DataCase, async: true

  import SimpleFit.CoachingHelpers, only: [coach_user!: 1, fighter_user!: 0]
  import SimpleFit.GymHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Gyms
  alias SimpleFit.Gyms.{AuditEvent, Gym, Policy, StaffMembership}

  describe "create_gym/3" do
    test "creates a draft gym and its owner membership together, with audit events" do
      owner = registered!()

      assert {:ok, view, :created} =
               Gyms.create_gym(
                 owner,
                 gym_attrs(%{"name" => "  Simple Boxing Gym  "}),
                 client_ip()
               )

      assert view.name == "Simple Boxing Gym"
      assert view.gym_type == :boxing_gym
      assert view.setup_status == :draft
      assert view.locations == []
      assert view.viewer.role == :owner
      assert :transfer_ownership in view.viewer.permissions

      gym = Repo.get!(Gym, view.id)
      assert gym.created_by_user_id == owner.id

      assert [%StaffMembership{user_id: user_id, role: :owner, status: :active} = owner_row] =
               active_owners(view.id)

      assert user_id == owner.id
      assert owner_row.id == view.viewer.staff_membership_id

      # One transaction, one timestamp: read by type.
      events = Map.new(audit_events(view.id), &{&1.event_type, &1})
      assert map_size(events) == 2
      assert %AuditEvent{actor_user_id: actor} = events.gym_created
      assert %AuditEvent{to_role: :owner} = bootstrap = events.staff_membership_created
      assert actor == owner.id and bootstrap.actor_user_id == owner.id
      assert bootstrap.staff_membership_id == owner_row.id
    end

    test "requires completed account registration and creates nothing otherwise" do
      {:ok, user} = Accounts.register_user(:google, "gym-unregistered-#{System.unique_integer()}")

      assert {:error, changeset} = Gyms.create_gym(user, gym_attrs(), client_ip())
      assert %{account_registration: [_]} = errors_on(changeset)
      assert gyms_created_by(user) == 0
    end

    test "validates the fields and rejects owners, roles and other unknown keys" do
      owner = registered!()

      for {attrs, field} <- [
            {%{"name" => ""}, :name},
            {%{"name" => String.duplicate("a", 81)}, :name},
            {%{"name" => "Gym\u0000"}, :name},
            {%{"gym_type" => "yoga_studio"}, :gym_type},
            {%{"client_request_id" => "not-a-uuid"}, :client_request_id}
          ] do
        assert {:error, changeset} = Gyms.create_gym(owner, gym_attrs(attrs), client_ip())
        assert Map.has_key?(errors_on(changeset), field), inspect(attrs)
      end

      for key <- ~w(owner_user_id role setup_status created_by_user_id gym_id) do
        assert {:error, changeset} =
                 Gyms.create_gym(owner, gym_attrs(%{key => Ecto.UUID.generate()}), client_ip())

        assert errors_on(changeset)[key] == ["is not a field of a gym"]
      end

      assert {:error, changeset} =
               Gyms.create_gym(owner, Map.delete(gym_attrs(), "client_request_id"), client_ip())

      assert %{client_request_id: ["can't be blank"]} = errors_on(changeset)
      assert gyms_created_by(owner) == 0
    end

    test "accepts each of the six design gym types" do
      for type <-
            ~w(boxing_gym boxing_club amateur_club professional_team combat_sports_gym fitness_boxing_studio) do
        owner = registered!()

        assert {:ok, %{gym_type: gym_type}, :created} =
                 Gyms.create_gym(owner, gym_attrs(%{"gym_type" => type}), client_ip())

        assert Atom.to_string(gym_type) == type
      end
    end

    test "a replayed client_request_id returns the same gym and creates nothing" do
      owner = registered!()
      attrs = gym_attrs()
      {:ok, first, :created} = Gyms.create_gym(owner, attrs, client_ip())

      assert {:ok, again, :existing} =
               Gyms.create_gym(owner, %{attrs | "name" => "Another name"}, client_ip())

      assert again.id == first.id
      assert again.name == first.name
      assert gyms_created_by(owner) == 1
    end

    test "with an open draft, a create with a new key resumes the draft" do
      owner = registered!()
      draft = draft_gym!(owner)

      assert {:ok, resumed, :resumed} =
               Gyms.create_gym(owner, gym_attrs(%{"name" => "Second"}), client_ip())

      assert resumed.id == draft.id
      assert gyms_created_by(owner) == 1
    end

    test "a completed gym frees the draft slot: no cap on completed gyms" do
      owner = registered!()
      for _ <- 1..4, do: completed_gym!(owner)

      assert {:ok, _view, :created} = Gyms.create_gym(owner, gym_attrs(), client_ip())
      assert gyms_created_by(owner) == 5
    end

    test "the same key used by another user is independent" do
      key = Ecto.UUID.generate()
      a = registered!()
      b = registered!()

      {:ok, gym_a, :created} =
        Gyms.create_gym(a, gym_attrs(%{"client_request_id" => key}), client_ip())

      {:ok, gym_b, :created} =
        Gyms.create_gym(b, gym_attrs(%{"client_request_id" => key}), client_ip())

      refute gym_a.id == gym_b.id
    end

    test "a replay after the creator lost access is a conflict, never the gym" do
      owner = registered!()
      manager = registered!()
      attrs = gym_attrs()
      {:ok, gym, :created} = Gyms.create_gym(owner, attrs, client_ip())
      complete!(gym.id)
      m = staff!(gym.id, manager, :manager)
      {:ok, _} = Gyms.transfer_ownership(owner, gym.id, m.id, :leave)

      assert {:error, {:conflict, %{client_request_id: "reused"}}} =
               Gyms.create_gym(owner, attrs, client_ip())
    end
  end

  describe "creation limits (D-G25)" do
    test "the user limit is rolling: it frees up only when the oldest creation is 24 h old" do
      owner = registered!()

      for _ <- 1..5 do
        {:ok, view, :created} = Gyms.create_gym(owner, gym_attrs(), client_ip())
        complete!(view.id)
      end

      assert {:error, {:rate_limited, retry_after}} =
               Gyms.create_gym(owner, gym_attrs(), client_ip())

      assert retry_after > 86_000

      # Age the counted events by 24 hours (as time would).
      Repo.update_all(
        from(e in "rate_limit_events", where: e.bucket == "gym_create_user"),
        set: [occurred_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -86_401)]
      )

      assert {:ok, _, :created} = Gyms.create_gym(owner, gym_attrs(), client_ip())
    end

    test "5 creations per user per window; the 6th is rate limited; replays are free" do
      owner = registered!()

      for _ <- 1..5 do
        attrs = gym_attrs()
        {:ok, view, :created} = Gyms.create_gym(owner, attrs, client_ip())
        # A replay of a successful create is not another creation.
        {:ok, _same, :existing} = Gyms.create_gym(owner, attrs, client_ip())
        complete!(view.id)
      end

      assert {:error, {:rate_limited, retry_after}} =
               Gyms.create_gym(owner, gym_attrs(), client_ip())

      assert retry_after in 1..86_400
      # Naive retries with new keys stay limited and create nothing.
      assert {:error, {:rate_limited, _}} = Gyms.create_gym(owner, gym_attrs(), client_ip())
      assert gyms_created_by(owner) == 5
    end

    test "a resumed draft is not counted" do
      owner = registered!()
      draft_gym!(owner)

      for _ <- 1..10,
          do: assert({:ok, _, :resumed} = Gyms.create_gym(owner, gym_attrs(), client_ip()))

      assert gyms_created_by(owner) == 1
    end

    test "20 creations per client key per window, across users" do
      ip = client_ip()

      for _ <- 1..20 do
        assert {:ok, _, :created} = Gyms.create_gym(registered!(), gym_attrs(), ip)
      end

      user = registered!()
      assert {:error, {:rate_limited, _}} = Gyms.create_gym(user, gym_attrs(), ip)
      assert gyms_created_by(user) == 0
      # Another client is unaffected.
      assert {:ok, _, :created} = Gyms.create_gym(user, gym_attrs(), client_ip())
    end

    test "invalid requests are rejected before the limits and do not consume them" do
      owner = registered!()

      for _ <- 1..10,
          do:
            {:error, %Ecto.Changeset{}} =
              Gyms.create_gym(owner, gym_attrs(%{"name" => ""}), client_ip())

      for _ <- 1..5 do
        {:ok, view, :created} = Gyms.create_gym(owner, gym_attrs(), client_ip())
        complete!(view.id)
      end
    end
  end

  describe "the role matrix (D-G03)" do
    setup do
      owner = registered!()
      gym = completed_gym!(owner)

      users =
        for role <- [:manager, :coach, :front_desk], into: %{owner: owner} do
          user = registered!()
          staff!(gym.id, user, role)
          {role, user}
        end

      %{gym: gym, users: users}
    end

    test "each role holds exactly its approved permissions", %{gym: gym, users: users} do
      expected = %{
        owner: Policy.permissions() -- [:leave_gym],
        manager:
          ~w(view_workspace view_staff edit_gym manage_locations invite_staff change_staff_role remove_staff
             leave_gym manage_member_enrollment view_members view_member_contact change_member_status
             manage_timetable cancel_occurrence view_rosters book_for_member record_check_in view_attendance)a,
        coach:
          ~w(view_workspace view_staff leave_gym view_members cancel_occurrence view_rosters record_check_in
             view_attendance)a,
        front_desk:
          ~w(view_workspace view_staff leave_gym manage_member_enrollment view_members view_member_contact
             view_rosters book_for_member record_check_in view_attendance)a
      }

      for {role, user} <- users, permission <- Policy.permissions() do
        result = Gyms.authorize(user, gym.id, permission)

        if permission in expected[role],
          do: assert({:ok, %{membership: %{role: ^role}}} = result, "#{role} #{permission}"),
          else: assert({:error, :forbidden} == result, "#{role} #{permission}")
      end
    end

    test "limited grants carry their scope", %{gym: gym, users: users} do
      assert {:ok, %{scope: :coach_and_front_desk}} =
               Gyms.authorize(users.manager, gym.id, :remove_staff)

      assert {:ok, %{scope: :own_classes}} = Gyms.authorize(users.coach, gym.id, :view_members)
      assert {:ok, %{scope: :today}} = Gyms.authorize(users.front_desk, gym.id, :view_attendance)
      assert {:ok, %{scope: :all}} = Gyms.authorize(users.owner, gym.id, :remove_staff)
    end

    test "the Gyms context never reads coaching, training or fighter data (D-G06)" do
      sources = ["lib/simple_fit/gyms.ex" | Path.wildcard("lib/simple_fit/gyms/**/*.ex")]
      assert length(sources) >= 8

      for path <- sources,
          forbidden <- ~w(SimpleFit.Coaching SimpleFit.Training SimpleFit.Fighters
                                            SimpleFit.Coaches coach_fighter_relationships training_sessions
                                            fighter_profiles coach_profiles) do
        refute File.read!(path) =~ forbidden, "#{path} references #{forbidden}"
      end
    end

    test "no permission reads private fighter training data, for any role" do
      for permission <- Policy.permissions() do
        refute Atom.to_string(permission) =~ ~r/training|rpe|weight|note|video|message|fighter/,
               "#{permission}"
      end
    end
  end

  describe "tenant isolation" do
    test "one user, two gyms, two independent roles" do
      a_owner = registered!()
      b_owner = registered!()
      person = registered!()
      gym_a = completed_gym!(a_owner)
      gym_b = completed_gym!(b_owner)
      staff!(gym_a.id, person, :manager)
      staff!(gym_b.id, person, :front_desk)

      assert {:ok, %{membership: %{role: :manager}}} =
               Gyms.authorize(person, gym_a.id, :manage_timetable)

      assert {:error, :forbidden} = Gyms.authorize(person, gym_b.id, :manage_timetable)

      assert {:ok, page} = Gyms.list_my_gyms(person, %{})

      assert page.entries |> Enum.map(&{&1.id, &1.viewer.role}) |> Enum.sort() ==
               Enum.sort([{gym_a.id, :manager}, {gym_b.id, :front_desk}])
    end

    test "outsiders, forged and malformed ids are not found, never forbidden" do
      owner = registered!()
      outsider = registered!()
      gym = completed_gym!(owner)

      for id <- [gym.id, Ecto.UUID.generate(), "not-a-uuid", "", nil, 42] do
        assert {:error, :not_found} = Gyms.get_gym(outsider, id)
        assert {:error, :not_found} = Gyms.authorize(outsider, id, :view_workspace)
      end

      assert {:error, :not_found} = Gyms.authorize(outsider, gym.id, :transfer_ownership)
      assert {:ok, %{entries: []}} = Gyms.list_my_gyms(outsider, %{})
    end

    test "a coach profile, a fighter profile or a coaching relationship grants nothing" do
      owner = registered!()
      gym = completed_gym!(owner)
      coach = coach_user!("Coach Ola")
      fighter = fighter_user!()

      for user <- [coach, fighter] do
        assert {:error, :not_found} = Gyms.get_gym(user, gym.id)
        assert {:ok, %{entries: []}} = Gyms.list_my_gyms(user, %{})
      end
    end

    test "an ended membership grants nothing" do
      owner = registered!()
      coach = registered!()
      gym = completed_gym!(owner)
      m = staff!(gym.id, coach, :coach)
      {:ok, _} = Gyms.revoke_staff_membership(owner, gym.id, m.id)

      assert {:error, :not_found} = Gyms.get_gym(coach, gym.id)
      assert {:error, :not_found} = Gyms.authorize(coach, gym.id, :record_check_in)
      assert {:ok, %{entries: []}} = Gyms.list_my_gyms(coach, %{})
    end
  end

  describe "list_my_gyms/2" do
    test "pages newest membership first with an opaque cursor" do
      owner = registered!()
      ids = for _ <- 1..3, do: completed_gym!(owner).id

      {:ok, %{entries: [a, b], next_cursor: cursor}} = Gyms.list_my_gyms(owner, %{"limit" => "2"})
      assert is_binary(cursor)
      {:ok, %{entries: [c], next_cursor: nil}} = Gyms.list_my_gyms(owner, %{"cursor" => cursor})
      assert [a.id, b.id, c.id] == Enum.reverse(ids)
      refute Map.has_key?(a, :locations)
    end

    test "rejects invalid limits and cursors" do
      owner = registered!()

      for params <- [%{"limit" => "0"}, %{"limit" => "101"}, %{"cursor" => "garbage"}] do
        assert {:error, %Ecto.Changeset{}} = Gyms.list_my_gyms(owner, params)
      end
    end
  end

  describe "revoke_staff_membership/3" do
    setup do
      owner = registered!()
      gym = completed_gym!(owner)
      manager = registered!()
      coach = registered!()
      desk = registered!()

      %{
        gym: gym,
        owner: owner,
        manager: {manager, staff!(gym.id, manager, :manager)},
        coach: {coach, staff!(gym.id, coach, :coach)},
        desk: {desk, staff!(gym.id, desk, :front_desk)},
        owner_row: hd(active_owners(gym.id))
      }
    end

    test "the owner revokes a manager; the next request is denied", ctx do
      {manager, m} = ctx.manager

      assert {:ok, %StaffMembership{status: :ended, ended_reason: :removed}} =
               Gyms.revoke_staff_membership(ctx.owner, ctx.gym.id, m.id)

      assert {:error, :not_found} = Gyms.authorize(manager, ctx.gym.id, :view_workspace)

      assert %AuditEvent{
               event_type: :staff_membership_ended,
               from_role: :manager,
               reason: :removed
             } =
               List.last(audit_events(ctx.gym.id))
    end

    test "a manager revokes coaches and front desk, never managers or the owner", ctx do
      {manager, _} = ctx.manager
      {_, coach_row} = ctx.coach
      other_manager = registered!()
      other = staff!(ctx.gym.id, other_manager, :manager)

      assert {:ok, _} = Gyms.revoke_staff_membership(manager, ctx.gym.id, coach_row.id)
      assert {:error, :forbidden} = Gyms.revoke_staff_membership(manager, ctx.gym.id, other.id)

      assert {:error, :forbidden} =
               Gyms.revoke_staff_membership(manager, ctx.gym.id, ctx.owner_row.id)
    end

    test "coaches and front desk revoke nobody", ctx do
      {coach, coach_row} = ctx.coach
      {desk, desk_row} = ctx.desk

      assert {:error, :forbidden} = Gyms.revoke_staff_membership(coach, ctx.gym.id, desk_row.id)
      assert {:error, :forbidden} = Gyms.revoke_staff_membership(desk, ctx.gym.id, coach_row.id)
    end

    test "the owner cannot revoke their own ownership", ctx do
      assert {:error, {:conflict, %{staff_membership: "owner_requires_transfer"}}} =
               Gyms.revoke_staff_membership(ctx.owner, ctx.gym.id, ctx.owner_row.id)

      assert [_] = active_owners(ctx.gym.id)
    end

    test "a membership of another gym, an ended one or a malformed id is not found", ctx do
      other_owner = registered!()
      other_gym = completed_gym!(other_owner)
      foreign = staff!(other_gym.id, registered!(), :coach)
      {_, coach_row} = ctx.coach
      {:ok, _} = Gyms.revoke_staff_membership(ctx.owner, ctx.gym.id, coach_row.id)

      for id <- [foreign.id, coach_row.id, Ecto.UUID.generate(), "nope"] do
        assert {:error, :not_found} = Gyms.revoke_staff_membership(ctx.owner, ctx.gym.id, id)
      end

      assert {:ok, _} = Gyms.authorize(other_owner, other_gym.id, :view_workspace)
    end

    test "outsiders get not found", ctx do
      {_, coach_row} = ctx.coach

      assert {:error, :not_found} =
               Gyms.revoke_staff_membership(registered!(), ctx.gym.id, coach_row.id)
    end
  end

  describe "transfer_ownership/4" do
    setup do
      owner = registered!()
      gym = completed_gym!(owner)
      manager = registered!()
      %{gym: gym, owner: owner, manager: manager, target: staff!(gym.id, manager, :manager)}
    end

    test "hands ownership to an active staff member; the old owner stays as manager", ctx do
      assert {:ok, %{owner: new_owner, previous_owner: stayed}} =
               Gyms.transfer_ownership(ctx.owner, ctx.gym.id, ctx.target.id, :stay_as_manager)

      assert new_owner.id == ctx.target.id
      assert [%StaffMembership{user_id: user_id}] = active_owners(ctx.gym.id)
      assert user_id == ctx.manager.id
      assert stayed.role == :manager and stayed.user_id == ctx.owner.id

      assert {:ok, %{membership: %{role: :manager}}} =
               Gyms.authorize(ctx.owner, ctx.gym.id, :view_workspace)

      assert {:error, :forbidden} = Gyms.authorize(ctx.owner, ctx.gym.id, :transfer_ownership)

      # One transition, one timestamp: compared as a set.
      assert Enum.sort([
               :ownership_transferred,
               :staff_membership_ended,
               :staff_membership_created
             ]) ==
               ctx.gym.id
               |> audit_events()
               |> Enum.drop(2)
               |> Enum.map(& &1.event_type)
               |> Enum.sort()
    end

    test "with :leave the previous owner loses all access", ctx do
      {:ok, %{previous_owner: nil}} =
        Gyms.transfer_ownership(ctx.owner, ctx.gym.id, ctx.target.id, :leave)

      assert {:error, :not_found} = Gyms.get_gym(ctx.owner, ctx.gym.id)
    end

    test "non-owners cannot transfer; outsiders get not found", ctx do
      coach = registered!()
      coach_row = staff!(ctx.gym.id, coach, :coach)

      assert {:error, :forbidden} =
               Gyms.transfer_ownership(ctx.manager, ctx.gym.id, coach_row.id, :leave)

      assert {:error, :not_found} =
               Gyms.transfer_ownership(registered!(), ctx.gym.id, coach_row.id, :leave)

      assert [%{user_id: user_id}] = active_owners(ctx.gym.id)
      assert user_id == ctx.owner.id
    end

    test "the target must be active staff of this gym; a draft cannot be transferred", ctx do
      outsider_row = staff!(completed_gym!(registered!()).id, registered!(), :manager)
      {:ok, _} = Gyms.revoke_staff_membership(ctx.owner, ctx.gym.id, ctx.target.id)
      owner_row = hd(active_owners(ctx.gym.id))

      for id <- [ctx.target.id, outsider_row.id, Ecto.UUID.generate(), "x"] do
        assert {:error, :not_found} = Gyms.transfer_ownership(ctx.owner, ctx.gym.id, id, :leave)
      end

      assert {:error, {:conflict, %{staff_membership: "already_owner"}}} =
               Gyms.transfer_ownership(ctx.owner, ctx.gym.id, owner_row.id, :leave)

      creator = registered!()
      draft = draft_gym!(creator)
      helper = staff!(draft.id, registered!(), :manager)

      assert {:error, {:conflict, %{setup_status: "draft"}}} =
               Gyms.transfer_ownership(creator, draft.id, helper.id, :leave)
    end

    test "a failed transfer records no audit event", ctx do
      before = audit_events(ctx.gym.id)

      {:error, :forbidden} =
        Gyms.transfer_ownership(ctx.manager, ctx.gym.id, ctx.target.id, :leave)

      {:error, :not_found} =
        Gyms.transfer_ownership(ctx.owner, ctx.gym.id, Ecto.UUID.generate(), :leave)

      assert audit_events(ctx.gym.id) == before
    end
  end

  describe "check_account_deletion/1 (D-G26)" do
    test "refuses while the user owns a completed gym, allows after a transfer" do
      owner = registered!()
      gym = completed_gym!(owner)

      assert {:error, {:conflict, %{gym_ownership: "transfer_required"}}} =
               Gyms.check_account_deletion(owner)

      m = staff!(gym.id, registered!(), :manager)
      {:ok, _} = Gyms.transfer_ownership(owner, gym.id, m.id, :leave)
      assert :ok = Gyms.check_account_deletion(owner)
    end

    test "a draft owner, staff and unrelated users are not blocked by the guard" do
      owner = registered!()
      gym = completed_gym!(owner)
      coach = registered!()
      staff!(gym.id, coach, :coach)
      drafter = registered!()
      draft_gym!(drafter)

      assert :ok = Gyms.check_account_deletion(coach)
      assert :ok = Gyms.check_account_deletion(drafter)
      assert :ok = Gyms.check_account_deletion(registered!())
    end
  end
end
