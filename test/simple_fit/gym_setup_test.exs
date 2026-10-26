defmodule SimpleFit.GymSetupTest do
  @moduledoc """
  Gym owner registration and setup (SF-85): partial updates and their null
  semantics, validation without truncation, optimistic concurrency, the
  primary location, completion, discard, permissions, database invariants
  and the real entry resolver before and after completion and discard.
  Concurrency is in `SimpleFit.GymSetupRaceTest`.
  """

  use SimpleFit.DataCase, async: true

  import SimpleFit.CoachingHelpers, only: [complete_coach!: 2]
  import SimpleFit.FighterOnboardingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.{Entry, Gyms}
  alias SimpleFit.Gyms.{AuditEvent, Gym, GymLocation, StaffMembership}

  @address %{"country_code" => "pl", "city" => " Warsaw ", "address_line" => "ul. Ząbkowska 31"}

  defp draft_with_owner do
    owner = registered!()
    %{owner: owner, gym: draft_gym!(owner)}
  end

  defp events(gym_id, type),
    do: gym_id |> audit_events() |> Enum.filter(&(&1.event_type == type))

  describe "get_setup/2" do
    test "a fresh draft misses only its primary location" do
      %{owner: owner, gym: gym} = draft_with_owner()

      assert {:ok, setup} = Gyms.get_setup(owner, gym.id)
      assert setup.setup_status == :draft
      assert setup.primary_location == nil
      assert setup.missing_requirements == [:primary_location]
      assert setup.revision == 1
      assert setup.viewer.role == :owner
    end

    test "outsiders, forged and malformed ids get not found" do
      %{gym: gym} = draft_with_owner()

      for id <- [gym.id, Ecto.UUID.generate(), "nope"] do
        assert {:error, :not_found} = Gyms.get_setup(registered!(), id)
      end
    end
  end

  describe "update_setup/3" do
    test "saves any subset; omitted fields are unchanged; revision bumps once per change" do
      %{owner: owner, gym: gym} = draft_with_owner()

      {:ok, s1} =
        Gyms.update_setup(owner, gym.id, %{
          "name" => "  Praga Boxing  ",
          "phone" => "+48 22 000 00 00",
          "website" => "https://simpleboxing.pl",
          "tagline" => "Boxing for everyone.",
          "accent_color" => "#AEB95A"
        })

      assert {s1.name, s1.phone, s1.website, s1.tagline, s1.accent_color} ==
               {"Praga Boxing", "+48 22 000 00 00", "https://simpleboxing.pl",
                "Boxing for everyone.", "#aeb95a"}

      assert s1.revision == 2

      {:ok, s2} = Gyms.update_setup(owner, gym.id, %{"gym_type" => "fitness_boxing_studio"})

      assert s2.gym_type == :fitness_boxing_studio and s2.name == "Praga Boxing" and
               s2.revision == 3
    end

    test "null or blank clears optional fields; name and type cannot be cleared" do
      %{owner: owner, gym: gym} = draft_with_owner()
      {:ok, _} = Gyms.update_setup(owner, gym.id, %{"phone" => "+48 1234567", "tagline" => "Hi"})

      {:ok, cleared} = Gyms.update_setup(owner, gym.id, %{"phone" => nil, "tagline" => "   "})
      assert cleared.phone == nil and cleared.tagline == nil

      for field <- ["name", "gym_type"], value <- [nil, ""] do
        assert {:error, changeset} = Gyms.update_setup(owner, gym.id, %{field => value})
        assert errors_on(changeset)[String.to_existing_atom(field)]
      end
    end

    test "an empty update changes nothing and creates nothing" do
      %{owner: owner, gym: gym} = draft_with_owner()
      {:ok, setup} = Gyms.update_setup(owner, gym.id, %{})
      assert setup.revision == 1
      assert gyms_created_by(owner) == 1
    end

    test "invalid values are rejected as a whole, never truncated or rounded" do
      %{owner: owner, gym: gym} = draft_with_owner()

      for {attrs, field} <- [
            {%{"name" => String.duplicate("a", 81)}, :name},
            {%{"name" => "Gym\u0007"}, :name},
            {%{"gym_type" => "yoga"}, :gym_type},
            {%{"phone" => "call me"}, :phone},
            {%{"website" => "javascript:alert(1)"}, :website},
            {%{"website" => "https://user:pass@example.com"}, :website},
            {%{"website" => "ftp://example.com"}, :website},
            {%{"website" => "https://example.com/" <> String.duplicate("a", 200)}, :website},
            {%{"tagline" => String.duplicate("t", 121)}, :tagline},
            {%{"accent_color" => "#123456"}, :accent_color},
            {%{"name" => 42}, :name}
          ] do
        assert {:error, changeset} = Gyms.update_setup(owner, gym.id, attrs)
        assert errors_on(changeset)[field], inspect(attrs)
      end

      assert Repo.get!(Gym, gym.id).revision == 1
    end

    test "read-only and unknown fields are rejected" do
      %{owner: owner, gym: gym} = draft_with_owner()

      for key <- ~w(setup_status revision owner_user_id created_by_user_id id primary_location) do
        assert {:error, changeset} = Gyms.update_setup(owner, gym.id, %{key => "x"})
        assert errors_on(changeset)[key] == ["is not a setup field"]
      end
    end

    test "a stale expected_revision changes nothing; the current one applies" do
      %{owner: owner, gym: gym} = draft_with_owner()
      {:ok, _} = Gyms.update_setup(owner, gym.id, %{"tagline" => "First"})

      assert {:error, {:conflict, %{revision: "stale"}}} =
               Gyms.update_setup(owner, gym.id, %{"tagline" => "Lost", "expected_revision" => 1})

      assert {:ok, %{tagline: "Second", revision: 3}} =
               Gyms.update_setup(owner, gym.id, %{"tagline" => "Second", "expected_revision" => 2})
    end

    test "a completed gym's profile stays editable; its status never returns to draft" do
      owner = registered!()
      gym = completed_gym!(owner)

      assert {:ok, %{name: "Renamed", setup_status: :completed}} =
               Gyms.update_setup(owner, gym.id, %{"name" => "Renamed"})
    end
  end

  describe "permissions" do
    setup do
      owner = registered!()
      gym = completed_gym!(owner)
      users = for role <- [:manager, :coach, :front_desk], into: %{}, do: {role, registered!()}
      Enum.each(users, fn {role, user} -> staff!(gym.id, user, role) end)
      %{owner: owner, gym: gym, users: users}
    end

    test "owner and manager edit; coach and front desk read but get forbidden", ctx do
      assert {:ok, _} = Gyms.update_setup(ctx.users.manager, ctx.gym.id, %{"tagline" => "Mgr"})
      assert {:ok, _} = Gyms.put_primary_location(ctx.users.manager, ctx.gym.id, @address)

      for role <- [:coach, :front_desk] do
        user = ctx.users[role]
        assert {:ok, _} = Gyms.get_setup(user, ctx.gym.id)
        assert {:error, :forbidden} = Gyms.update_setup(user, ctx.gym.id, %{"tagline" => "x"})
        assert {:error, :forbidden} = Gyms.put_primary_location(user, ctx.gym.id, @address)
      end
    end

    test "only the owner completes or discards; a manager is forbidden", ctx do
      draft = draft_gym!(registered!())
      manager = registered!()
      staff!(draft.id, manager, :manager)

      assert {:error, :forbidden} = Gyms.complete_setup(manager, draft.id)
      assert {:error, :forbidden} = Gyms.discard_draft(manager, draft.id)
      assert {:error, :forbidden} = Gyms.complete_setup(ctx.users.manager, ctx.gym.id)
    end

    test "outsiders and revoked staff get not found for every setup operation", ctx do
      outsider = registered!()
      revoked = ctx.users.coach
      [m] = Repo.all(from(m in StaffMembership, where: m.user_id == ^revoked.id))
      {:ok, _} = Gyms.revoke_staff_membership(ctx.owner, ctx.gym.id, m.id)

      for user <- [outsider, revoked] do
        assert {:error, :not_found} = Gyms.get_setup(user, ctx.gym.id)
        assert {:error, :not_found} = Gyms.update_setup(user, ctx.gym.id, %{"tagline" => "x"})
        assert {:error, :not_found} = Gyms.put_primary_location(user, ctx.gym.id, @address)
        assert {:error, :not_found} = Gyms.complete_setup(user, ctx.gym.id)
        assert {:error, :not_found} = Gyms.discard_draft(user, ctx.gym.id)
      end
    end
  end

  describe "put_primary_location/3" do
    test "creates the primary location once, then replaces it in place" do
      %{owner: owner, gym: gym} = draft_with_owner()

      {:ok, s1} =
        Gyms.put_primary_location(owner, gym.id, Map.put(@address, "entrance_note", "Courtyard"))

      loc = s1.primary_location

      assert {loc.country_code, loc.city, loc.name, loc.entrance_note} ==
               {"PL", "Warsaw", "Warsaw", "Courtyard"}

      assert s1.missing_requirements == [] and s1.revision == 2

      {:ok, s2} =
        Gyms.put_primary_location(owner, gym.id, %{
          "country_code" => "PL",
          "city" => "Warsaw",
          "address_line" => "ul. Wolska 50",
          "name" => "Wola"
        })

      assert s2.primary_location.id == loc.id
      assert s2.primary_location.name == "Wola" and s2.primary_location.entrance_note == nil
      assert Repo.aggregate(from(l in GymLocation, where: l.gym_id == ^gym.id), :count) == 1
    end

    test "an identical address changes nothing and records no event" do
      %{owner: owner, gym: gym} = draft_with_owner()
      {:ok, s1} = Gyms.put_primary_location(owner, gym.id, @address)
      {:ok, s2} = Gyms.put_primary_location(owner, gym.id, @address)

      assert s2.revision == s1.revision
      assert length(events(gym.id, :primary_location_set)) == 1
    end

    test "incomplete or invalid addresses are rejected and nothing is stored" do
      %{owner: owner, gym: gym} = draft_with_owner()

      for {attrs, field} <- [
            {Map.delete(@address, "city"), :city},
            {Map.delete(@address, "address_line"), :address_line},
            {%{@address | "country_code" => "XX"}, :country_code},
            {%{@address | "country_code" => "Poland"}, :country_code},
            {Map.put(@address, "entrance_note", String.duplicate("n", 201)), :entrance_note}
          ] do
        assert {:error, changeset} = Gyms.put_primary_location(owner, gym.id, attrs)
        assert errors_on(changeset)[field], inspect(field)
      end

      assert {:error, changeset} =
               Gyms.put_primary_location(owner, gym.id, Map.put(@address, "lat", 1))

      assert errors_on(changeset)["lat"] == ["is not a setup field"]
      assert Repo.aggregate(from(l in GymLocation, where: l.gym_id == ^gym.id), :count) == 0
    end

    test "the audit event carries no address" do
      %{owner: owner, gym: gym} = draft_with_owner()
      {:ok, _} = Gyms.put_primary_location(owner, gym.id, @address)

      [event] = events(gym.id, :primary_location_set)
      refute inspect(Map.from_struct(event)) =~ "Ząbkowska"
      refute inspect(Map.from_struct(event)) =~ "Warsaw"
    end
  end

  describe "complete_setup/2" do
    test "an incomplete draft names what is missing and stays a draft" do
      %{owner: owner, gym: gym} = draft_with_owner()

      assert {:error, changeset} = Gyms.complete_setup(owner, gym.id)
      assert %{primary_location: ["is required to complete setup"]} = errors_on(changeset)
      assert Repo.get!(Gym, gym.id).setup_status == :draft
      assert events(gym.id, :setup_completed) == []
    end

    test "invalid input followed by a valid retry completes" do
      %{owner: owner, gym: gym} = draft_with_owner()
      {:error, _} = Gyms.put_primary_location(owner, gym.id, Map.delete(@address, "city"))
      {:ok, _} = Gyms.put_primary_location(owner, gym.id, @address)

      assert {:ok, %{setup_status: :completed, missing_requirements: []}, :completed} =
               Gyms.complete_setup(owner, gym.id)
    end

    test "completion is recorded once; repeating it is a safe no-op" do
      %{owner: owner, gym: gym} = draft_with_owner()
      {:ok, _} = Gyms.put_primary_location(owner, gym.id, @address)

      {:ok, first, :completed} = Gyms.complete_setup(owner, gym.id)
      {:ok, again, :already_completed} = Gyms.complete_setup(owner, gym.id)

      assert again.revision == first.revision
      assert length(events(gym.id, :setup_completed)) == 1
      assert length(active_owners(gym.id)) == 1
    end

    test "the entry resolver: draft resumes setup, completion opens the gym, other contexts stay" do
      owner = registered!()
      complete_fighter_onboarding!(owner)
      complete_coach!(owner, "Coach Ola")
      gym = draft_gym!(owner)

      {:ok, before} = Entry.resolve(owner, %{"intent" => "gym"})
      assert {before.destination, before.gym_id} == {:gym_onboarding, gym.id}
      assert before.capabilities == [:fighter, :coach]

      {:ok, _} = Gyms.put_primary_location(owner, gym.id, @address)
      {:ok, _, :completed} = Gyms.complete_setup(owner, gym.id)

      {:ok, after_completion} = Entry.resolve(owner, %{"intent" => "gym"})
      assert {after_completion.destination, after_completion.gym_id} == {:gym_home, gym.id}
      assert after_completion.capabilities == [:fighter, :coach, :gym_workspace]
    end
  end

  describe "discard_draft/2" do
    test "deletes the draft and what belongs to it; keeps a minimal audit event" do
      %{owner: owner, gym: gym} = draft_with_owner()
      {:ok, _} = Gyms.put_primary_location(owner, gym.id, @address)

      assert :ok = Gyms.discard_draft(owner, gym.id)

      assert Repo.get(Gym, gym.id) == nil
      assert Repo.aggregate(from(m in StaffMembership, where: m.gym_id == ^gym.id), :count) == 0
      assert Repo.aggregate(from(l in GymLocation, where: l.gym_id == ^gym.id), :count) == 0
      assert [%AuditEvent{actor_user_id: actor}] = events(gym.id, :draft_discarded)
      assert actor == owner.id

      # Repeating answers not found; the entry no longer resumes it; the slot is free.
      assert {:error, :not_found} = Gyms.discard_draft(owner, gym.id)
      {:ok, entry} = Entry.resolve(owner, %{"intent" => "gym"})

      assert {entry.destination, entry.reason, entry.gym_workspaces} ==
               {:gym_onboarding, :gym_setup_not_started, []}

      assert {:ok, _, :created} = Gyms.create_gym(owner, gym_attrs(), client_ip())
    end

    test "a completed gym is never discarded" do
      owner = registered!()
      gym = completed_gym!(owner)

      assert {:error, {:conflict, %{setup_status: "completed"}}} =
               Gyms.discard_draft(owner, gym.id)

      assert Repo.get(Gym, gym.id)
    end
  end

  describe "multiple gyms" do
    test "an owner completes one gym, then creates and keeps a second draft independent" do
      owner = registered!()
      first = draft_gym!(owner)
      {:ok, _} = Gyms.put_primary_location(owner, first.id, @address)
      {:ok, _, :completed} = Gyms.complete_setup(owner, first.id)

      {:ok, second, :created} =
        Gyms.create_gym(owner, gym_attrs(%{"name" => "Second"}), client_ip())

      {:ok, _} = Gyms.update_setup(owner, second.id, %{"tagline" => "Only here"})

      assert {:ok, %{tagline: nil}} = Gyms.get_setup(owner, first.id)
      {:ok, entry} = Entry.resolve(owner, %{"intent" => "gym"})
      assert entry.destination == :gym_selection

      assert entry.gym_workspaces |> Enum.map(& &1.setup_status) |> Enum.sort() == [
               :completed,
               :draft
             ]
    end
  end

  describe "database invariants" do
    test "a draft cannot be completed without an active primary location" do
      %{gym: gym} = draft_with_owner()

      assert_raise Postgrex.Error, ~r/active primary location to complete setup/, fn ->
        Repo.update_all(from(g in Gym, where: g.id == ^gym.id), set: [setup_status: :completed])
      end
    end

    test "a completed gym cannot lose its last active primary location" do
      owner = registered!()
      gym = completed_gym!(owner)

      assert_raise Postgrex.Error, ~r/keeps an active primary location/, fn ->
        Repo.update_all(from(l in GymLocation, where: l.gym_id == ^gym.id),
          set: [archived_at: DateTime.utc_now()]
        )
      end

      assert_raise Postgrex.Error, ~r/keeps an active primary location/, fn ->
        Repo.delete_all(from(l in GymLocation, where: l.gym_id == ^gym.id))
      end
    end

    test "unapproved accent colours and unsafe websites are refused by the database too" do
      %{gym: gym} = draft_with_owner()

      for set <- [
            [accent_color: "#000000"],
            [website: "javascript:alert(1)"],
            [tagline: " padded "]
          ] do
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(from(g in Gym, where: g.id == ^gym.id), set: set)
        end
      end
    end
  end
end
