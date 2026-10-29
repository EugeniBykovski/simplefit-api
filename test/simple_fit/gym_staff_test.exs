defmodule SimpleFit.GymStaffTest do
  @moduledoc """
  A gym's staff (SF-93; ADR 0026 D-G03, D-G04, D-G06): the roster, role
  changes within the matrix, removal and leaving, coach affiliation without
  any CoachProfile or Coach–Fighter effect, multi-gym independence and the
  separation from private fighter training data.

  Not async: the coaching fixtures set the global sharing configuration.
  """

  use SimpleFit.DataCase, async: false

  import SimpleFit.CoachingHelpers
  import SimpleFit.GymHelpers
  import SimpleFit.TrainingHelpers

  alias SimpleFit.Accounts.Sessions
  alias SimpleFit.{Coaches, Coaching, Gyms, Repo, Training}
  alias SimpleFit.Coaching.Relationship
  alias SimpleFit.Gyms.{AuditEvent, StaffMembership}

  setup do
    owner = registered_as!(registered!("staff-owner"), "Yauheni Bykovski")
    gym = completed_gym!(owner)

    {manager, %{staff_membership_id: manager_id}} =
      joined_staff!(owner, gym.id, :manager, "Agnieszka Lis")

    {coach, %{staff_membership_id: coach_id}} =
      joined_staff!(owner, gym.id, :coach, "Tomasz Zieliński")

    {desk, %{staff_membership_id: desk_id}} =
      joined_staff!(owner, gym.id, :front_desk, "Michał Sowa")

    %{
      owner: owner,
      gym: gym,
      manager: manager,
      manager_id: manager_id,
      coach: coach,
      coach_id: coach_id,
      desk: desk,
      desk_id: desk_id
    }
  end

  defp role!(actor, gym_id, id, role),
    do: Gyms.change_staff_role(actor, gym_id, id, %{"role" => to_string(role)})

  defp ended_events(gym_id),
    do: gym_id |> audit_events() |> Enum.filter(&(&1.event_type == :staff_membership_ended))

  describe "roster" do
    test "every staff role sees the active roster: short names and gym facts only", ctx do
      for viewer <- [ctx.owner, ctx.manager, ctx.coach, ctx.desk] do
        assert {:ok, %{entries: entries, next_cursor: nil}} =
                 Gyms.list_staff(viewer, ctx.gym.id, %{})

        assert Enum.map(entries, &{&1.role, &1.name}) == [
                 {:owner, "Yauheni B."},
                 {:manager, "Agnieszka L."},
                 {:coach, "Tomasz Z."},
                 {:front_desk, "Michał S."}
               ]

        assert Enum.count(entries, & &1.is_viewer) == 1

        for entry <- entries do
          assert Map.keys(entry) |> Enum.sort() ==
                   ~w(ended_at ended_reason is_viewer joined_at name role staff_membership_id status)a

          refute inspect(entry) =~ "@example.com"
        end
      end
    end

    test "ended staff: owner and managers only", ctx do
      {:ok, _} = Gyms.end_staff_membership(ctx.owner, ctx.gym.id, ctx.desk_id)

      assert {:ok, %{entries: [%{staff_membership_id: id, ended_reason: :removed}]}} =
               Gyms.list_staff(ctx.manager, ctx.gym.id, %{"status" => "ended"})

      assert id == ctx.desk_id

      assert Gyms.list_staff(ctx.coach, ctx.gym.id, %{"status" => "ended"}) ==
               {:error, :forbidden}

      assert {:error, %Ecto.Changeset{}} =
               Gyms.list_staff(ctx.owner, ctx.gym.id, %{"status" => "x"})
    end

    test "pages, and another gym's roster is not_found", ctx do
      assert {:ok, %{entries: [first, second], next_cursor: cursor}} =
               Gyms.list_staff(ctx.owner, ctx.gym.id, %{"limit" => "2"})

      assert {:ok, %{entries: [third, fourth], next_cursor: nil}} =
               Gyms.list_staff(ctx.owner, ctx.gym.id, %{"limit" => "2", "cursor" => cursor})

      assert length(Enum.uniq_by([first, second, third, fourth], & &1.staff_membership_id)) == 4

      other_owner = registered!("other")
      other = completed_gym!(other_owner)
      assert Gyms.list_staff(ctx.owner, other.id, %{}) == {:error, :not_found}
      assert Gyms.list_staff(other_owner, ctx.gym.id, %{}) == {:error, :not_found}
    end
  end

  describe "role changes" do
    test "the owner changes any non-owner role; audited; takes effect on the next request", ctx do
      assert {:ok, %{role: :manager}} = role!(ctx.owner, ctx.gym.id, ctx.desk_id, :manager)

      assert {:ok, %{role: :manager}} =
               Gyms.authorize(ctx.desk, ctx.gym.id, :invite_staff) |> role_of()

      assert [%AuditEvent{from_role: :front_desk, to_role: :manager, actor_user_id: actor}] =
               ctx.gym.id
               |> audit_events()
               |> Enum.filter(&(&1.event_type == :staff_role_changed))

      assert actor == ctx.owner.id

      assert {:ok, %{role: :coach}} = role!(ctx.owner, ctx.gym.id, ctx.manager_id, :coach)
      assert Gyms.authorize(ctx.manager, ctx.gym.id, :invite_staff) == {:error, :forbidden}
    end

    test "a manager switches coaches and front desk only", ctx do
      assert {:ok, %{role: :front_desk}} =
               role!(ctx.manager, ctx.gym.id, ctx.coach_id, :front_desk)

      assert role!(ctx.manager, ctx.gym.id, ctx.coach_id, :manager) == {:error, :forbidden}
      {_, %{staff_membership_id: other_manager}} = joined_staff!(ctx.owner, ctx.gym.id, :manager)
      assert role!(ctx.manager, ctx.gym.id, other_manager, :coach) == {:error, :forbidden}
    end

    test "nobody changes their own role, nobody becomes owner, the owner never changes", ctx do
      owner_id = owner_membership_id(ctx.gym.id)

      assert role!(ctx.manager, ctx.gym.id, ctx.manager_id, :coach) == {:error, :forbidden}
      assert role!(ctx.coach, ctx.gym.id, ctx.coach_id, :manager) == {:error, :forbidden}
      assert role!(ctx.desk, ctx.gym.id, ctx.desk_id, :manager) == {:error, :forbidden}

      assert {:error, %Ecto.Changeset{} = cs} =
               role!(ctx.owner, ctx.gym.id, ctx.manager_id, :owner)

      assert {"is invalid", _} = cs.errors[:role]

      assert role!(ctx.owner, ctx.gym.id, owner_id, :manager) ==
               {:error, {:conflict, %{staff_membership: "owner_requires_transfer"}}}

      assert role!(ctx.manager, ctx.gym.id, owner_id, :coach) ==
               {:error, {:conflict, %{staff_membership: "owner_requires_transfer"}}}

      assert [_] = active_owners(ctx.gym.id)
    end

    test "coaches and front desk change nobody; forged and foreign ids are not_found", ctx do
      assert role!(ctx.coach, ctx.gym.id, ctx.desk_id, :coach) == {:error, :forbidden}
      assert role!(ctx.desk, ctx.gym.id, ctx.coach_id, :front_desk) == {:error, :forbidden}
      assert role!(ctx.owner, ctx.gym.id, Ecto.UUID.generate(), :coach) == {:error, :not_found}
      assert role!(ctx.owner, ctx.gym.id, "nope", :coach) == {:error, :not_found}

      other_owner = registered!("other")
      other = completed_gym!(other_owner)
      {_, %{staff_membership_id: foreign}} = joined_staff!(other_owner, other.id, :coach)
      assert role!(ctx.owner, ctx.gym.id, foreign, :front_desk) == {:error, :not_found}
      assert role!(ctx.owner, other.id, foreign, :front_desk) == {:error, :not_found}
    end

    test "the same role changes nothing; any other field is refused", ctx do
      assert {:ok, %{role: :coach}} = role!(ctx.owner, ctx.gym.id, ctx.coach_id, :coach)
      refute Enum.any?(audit_events(ctx.gym.id), &(&1.event_type == :staff_role_changed))

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Gyms.change_staff_role(ctx.owner, ctx.gym.id, ctx.coach_id, %{
                 "role" => "front_desk",
                 "user_id" => ctx.owner.id
               })
    end
  end

  describe "removal and leaving" do
    test "removal: immediate loss of access, history kept, session and other gyms untouched",
         ctx do
      other_owner = registered!("other")
      other = completed_gym!(other_owner)
      email = address("two-gyms")
      link_email!(ctx.coach, email)
      %{invitation_id: id} = invite!(other_owner, other.id, email, :manager)
      accept!(ctx.coach, id)
      session = live_session!(ctx.coach)

      assert {:ok, %StaffMembership{status: :ended, ended_reason: :removed}} =
               Gyms.end_staff_membership(ctx.manager, ctx.gym.id, ctx.coach_id)

      assert Gyms.get_gym(ctx.coach, ctx.gym.id) == {:error, :not_found}
      assert Gyms.list_staff(ctx.coach, ctx.gym.id, %{}) == {:error, :not_found}
      assert {:ok, %{viewer: %{role: :manager}}} = Gyms.get_gym(ctx.coach, other.id)
      assert {:ok, _} = SimpleFit.Accounts.authenticate_access_token(token_of(session))
      assert [%AuditEvent{reason: :removed, from_role: :coach}] = ended_events(ctx.gym.id)
      assert Repo.get!(StaffMembership, ctx.coach_id).status == :ended

      # A repeat finds no active membership.
      assert Gyms.end_staff_membership(ctx.manager, ctx.gym.id, ctx.coach_id) ==
               {:error, :not_found}
    end

    test "who removes whom", ctx do
      owner_id = owner_membership_id(ctx.gym.id)

      assert Gyms.end_staff_membership(ctx.manager, ctx.gym.id, owner_id) == {:error, :forbidden}
      {_, %{staff_membership_id: other_manager}} = joined_staff!(ctx.owner, ctx.gym.id, :manager)

      assert Gyms.end_staff_membership(ctx.manager, ctx.gym.id, other_manager) ==
               {:error, :forbidden}

      assert Gyms.end_staff_membership(ctx.coach, ctx.gym.id, ctx.desk_id) == {:error, :forbidden}
      assert Gyms.end_staff_membership(ctx.desk, ctx.gym.id, ctx.coach_id) == {:error, :forbidden}

      assert Gyms.end_staff_membership(ctx.owner, ctx.gym.id, owner_id) ==
               {:error, {:conflict, %{staff_membership: "owner_requires_transfer"}}}

      assert {:ok, _} = Gyms.end_staff_membership(ctx.owner, ctx.gym.id, ctx.manager_id)
      assert [_] = active_owners(ctx.gym.id)
    end

    test "managers, coaches and front desk may leave; the owner may not", ctx do
      for {user, id} <- [
            {ctx.manager, ctx.manager_id},
            {ctx.coach, ctx.coach_id},
            {ctx.desk, ctx.desk_id}
          ] do
        assert {:ok, %StaffMembership{ended_reason: :left}} =
                 Gyms.end_staff_membership(user, ctx.gym.id, id)

        assert Gyms.get_gym(user, ctx.gym.id) == {:error, :not_found}
      end

      assert Enum.map(ended_events(ctx.gym.id), & &1.reason) == [:left, :left, :left]

      assert Gyms.end_staff_membership(ctx.owner, ctx.gym.id, owner_membership_id(ctx.gym.id)) ==
               {:error, {:conflict, %{staff_membership: "owner_requires_transfer"}}}
    end

    test "rejoining after an end is a new membership through a new invitation", ctx do
      email = address("rejoin")
      link_email!(ctx.desk, email)
      {:ok, _} = Gyms.end_staff_membership(ctx.owner, ctx.gym.id, ctx.desk_id)

      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      %{staff_membership_id: new_id} = accept!(ctx.desk, id)

      assert new_id != ctx.desk_id
      assert Repo.get!(StaffMembership, ctx.desk_id).status == :ended
      assert [%{id: ^new_id, role: :coach}] = active_memberships(ctx.gym.id, ctx.desk)
    end
  end

  describe "coach affiliation (D-G06)" do
    setup do
      configure_sharing()
      :ok
    end

    test "an existing CoachProfile joins as coach: profile unchanged, no relationship created",
         ctx do
      coach = coach_user!("Coach Marek")
      email = address("coach")
      link_email!(coach, email)
      profile = Coaches.get_profile(coach)
      relationships = Repo.aggregate(Relationship, :count)

      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      assert %{role: :coach} = accept!(coach, id)

      assert Coaches.get_profile(coach) == profile
      assert Repo.aggregate(Relationship, :count) == relationships
      assert {:ok, %{entries: []}} = Coaching.list_coach_relationships(coach, %{})
    end

    test "a gym coach needs no CoachProfile, and none is created", ctx do
      email = address("no-profile")
      user = email_user!(email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      assert %{role: :coach} = accept!(user, id)
      assert Coaches.get_profile(user) == nil
    end

    test "one coach in two gyms: two memberships, independent roles; ending one keeps the other",
         ctx do
      coach = coach_user!("Coach Ola")
      email = address("two")
      link_email!(coach, email)
      other_owner = registered!("other")
      other = completed_gym!(other_owner)

      %{staff_membership_id: a} =
        accept!(coach, invite!(ctx.owner, ctx.gym.id, email, :coach).invitation_id)

      %{staff_membership_id: b} =
        accept!(coach, invite!(other_owner, other.id, email, :manager).invitation_id)

      assert {:ok, %{membership: %{role: :coach}}} =
               Gyms.authorize(coach, ctx.gym.id, :view_staff)

      assert {:ok, %{membership: %{role: :manager}}} =
               Gyms.authorize(coach, other.id, :invite_staff)

      assert Gyms.authorize(coach, ctx.gym.id, :invite_staff) == {:error, :forbidden}

      {:ok, _} = Gyms.end_staff_membership(ctx.owner, ctx.gym.id, a)
      assert Gyms.get_gym(coach, ctx.gym.id) == {:error, :not_found}
      assert {:ok, _} = Gyms.get_gym(coach, other.id)
      assert Repo.get!(StaffMembership, b).status == :active
      assert Coaches.get_profile(coach).onboarding_completed_at
    end

    test "no gym role reaches a fighter's private training data", ctx do
      gym_coach = coach_user!("Coach Gym")
      email = address("gym-coach")
      link_email!(gym_coach, email)
      accept!(gym_coach, invite!(ctx.owner, ctx.gym.id, email, :coach).invitation_id)

      # A fighter who also works the front desk here, coached by someone else.
      fighter_email = address("fighter")
      fighter = email_fighter!(fighter_email)
      registered_as!(fighter, "Kasia Fighter")
      accept!(fighter, invite!(ctx.owner, ctx.gym.id, fighter_email, :front_desk).invitation_id)
      outside_coach = coach_user!("Coach Outside")
      relationship = activate!(outside_coach, fighter)
      session = assign!(outside_coach, relationship.id)

      for staff <- [gym_coach, ctx.coach, ctx.owner, ctx.manager] do
        assert {:ok, %{entries: []}} = Coaching.list_coach_relationships(staff, %{}) |> or_empty()
        assert Training.get_coach_session(staff, session.id) == {:error, :not_found}
        assert {:ok, %{entries: []}} = Training.list_coach_sessions(staff, %{}) |> or_empty()
      end

      # The roster shows the fighter only as front desk staff, with nothing from training.
      {:ok, %{entries: entries}} = Gyms.list_staff(gym_coach, ctx.gym.id, %{})
      kasia = Enum.find(entries, &(&1.name == "Kasia F."))
      assert kasia.role == :front_desk
      refute inspect(entries) =~ "Technical boxing"
    end
  end

  # A staff member without a coach profile reads no relationship or session:
  # `not_found` from the coaching side is as good as an empty list here.
  defp or_empty({:error, :not_found}), do: {:ok, %{entries: []}}
  defp or_empty(other), do: other

  defp role_of({:ok, %{membership: membership}}), do: {:ok, membership}
  defp role_of(other), do: other

  defp owner_membership_id(gym_id) do
    [%StaffMembership{id: id}] = active_owners(gym_id)
    id
  end

  defp token_of(session) do
    Sessions.sign_access_token_at(session.id, DateTime.utc_now())
  end
end
