defmodule SimpleFit.CoachingTest do
  @moduledoc """
  Coach–Fighter relationships (ADR 0021): the trusted activation boundary,
  database invariants, lifecycle, relationship-scoped authorization, the
  disclosure contract, the sharing gate and paging.
  """

  # Not async: the sharing gate and disclosure versions are global configuration.
  use SimpleFit.DataCase, async: false

  import SimpleFit.CoachingHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.{Accounts, Coaches, Coaching, Fighters}
  alias SimpleFit.Coaching.{Activation, Disclosure, Relationship}

  setup do
    configure_sharing()
    :ok
  end

  defp coach_id(user), do: Coaches.get_profile(user).id
  defp fighter_id(user), do: Fighters.get_profile(user).id

  defp roster(coach, params \\ %{}) do
    {:ok, page} = Coaching.list_coach_relationships(coach, params)
    page
  end

  defp coaches(fighter, params \\ %{}) do
    {:ok, page} = Coaching.list_fighter_relationships(fighter, params)
    page
  end

  defp raw_insert(coach_profile_id, fighter_profile_id, attrs \\ %{}) do
    now = DateTime.utc_now()

    Repo.insert_all(Relationship, [
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          coach_profile_id: coach_profile_id,
          fighter_profile_id: fighter_profile_id,
          status: :active,
          disclosure_version: version(),
          started_at: now,
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    ])
  end

  describe "activation (trusted boundary)" do
    test "creates an active relationship with the accepted disclosure version" do
      coach = coach_user!()
      fighter = fighter_user!()

      assert {:ok, %Relationship{} = r, :created} =
               Activation.activate(coach_id(coach), fighter, version())

      assert r.status == :active
      assert r.disclosure_version == version()
      assert r.coach_profile_id == coach_id(coach)
      assert r.fighter_profile_id == fighter_id(fighter)
      assert %DateTime{} = r.started_at
      assert r.ended_at == nil and r.ended_by == nil
    end

    test "a repeated acceptance converges on the existing active relationship" do
      coach = coach_user!()
      fighter = fighter_user!()
      first = activate!(coach, fighter)

      assert {:ok, again, :existing} = Activation.activate(coach_id(coach), fighter, version())
      assert again.id == first.id
      assert Repo.aggregate(Relationship, :count) == 1
    end

    test "fails closed while sharing is disabled, even with a configured version" do
      set_sharing(enabled: false)

      assert {:error, :sharing_disabled} =
               Activation.activate(coach_id(coach_user!()), fighter_user!(), version())

      assert Repo.aggregate(Relationship, :count) == 0
    end

    test "accepts only a configured disclosure version; none is assumed" do
      coach = coach_user!()
      fighter = fighter_user!()

      for bad <- ["fighter-disclosure-v1", "", nil, :basic_profile, true] do
        assert {:error, :disclosure_not_offered} =
                 Activation.activate(coach_id(coach), fighter, bad)
      end

      # Configured but not in the legal document registry: not offered.
      set_sharing(
        disclosures: %{
          version() => :basic_profile,
          "fighter-coach-disclosure-test-9" => :basic_profile
        }
      )

      assert {:error, :disclosure_not_offered} =
               Activation.activate(coach_id(coach), fighter, "fighter-coach-disclosure-test-9")

      assert Repo.aggregate(Relationship, :count) == 0
    end

    test "requires a completed fighter profile" do
      coach = coach_user!()
      started = registered_user!()
      {:ok, _} = Fighters.update_profile(started, %{"display_name" => "Half done"})

      for user <- [registered_user!(), started] do
        assert {:error, :fighter_not_completed} =
                 Activation.activate(coach_id(coach), user, version())
      end
    end

    test "requires an existing, completed coach profile" do
      fighter = fighter_user!()
      incomplete = registered_user!()
      {:ok, _} = Coaches.update_profile(incomplete, %{"display_name" => "Not yet"})

      for id <- [coach_id(incomplete), Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :coach_unavailable} = Activation.activate(id, fighter, version())
      end
    end

    test "a user holding both profiles cannot coach themselves" do
      both = coach_user!() |> complete_fighter_onboarding!()

      assert {:error, :self_coaching} = Activation.activate(coach_id(both), both, version())
      assert Repo.aggregate(Relationship, :count) == 0
    end

    test "a fighter may have several coaches and a coach several fighters" do
      fighter = fighter_user!()
      [c1, c2, c3] = for i <- 1..3, do: coach_user!("Coach #{i}")
      for coach <- [c1, c2, c3], do: activate!(coach, fighter)
      other_fighter = fighter_user!()
      activate!(c1, other_fighter)

      assert length(coaches(fighter).entries) == 3
      assert length(roster(c1).entries) == 2
    end

    test "no web module can reach the activation boundary" do
      offenders =
        Path.wildcard("lib/simple_fit_web/**/*.ex")
        |> Enum.filter(&(File.read!(&1) =~ ~r/Activation|activate\(/))

      assert offenders == []
    end
  end

  describe "database invariants" do
    setup do
      %{coach: coach_user!(), fighter: fighter_user!()}
    end

    test "at most one active relationship per pair", %{coach: c, fighter: f} do
      raw_insert(coach_id(c), fighter_id(f))

      assert_raise Postgrex.Error, ~r/active_pair_index/, fn ->
        raw_insert(coach_id(c), fighter_id(f))
      end
    end

    test "ended relationships of a pair coexist with a new active one", %{coach: c, fighter: f} do
      r1 = activate!(c, f)
      :ok = Coaching.end_relationship(c, :coach, r1.id)
      r2 = activate!(c, f)
      :ok = Coaching.end_relationship(f, :fighter, r2.id)
      r3 = activate!(c, f)

      assert length(Enum.uniq([r1.id, r2.id, r3.id])) == 3
      assert Repo.aggregate(from(r in Relationship, where: r.status == :active), :count) == 1
      assert Repo.aggregate(from(r in Relationship, where: r.status == :ended), :count) == 2
    end

    test "a relationship is created active only", %{coach: c, fighter: f} do
      now = DateTime.utc_now()

      assert_raise Postgrex.Error, ~r/created_active|lifecycle/, fn ->
        raw_insert(coach_id(c), fighter_id(f), %{
          status: :ended,
          ended_at: now,
          ended_by: :coach
        })
      end
    end

    test "both profiles must be completed", %{coach: c, fighter: f} do
      half = registered_user!()
      {:ok, _} = Fighters.update_profile(half, %{"display_name" => "Half"})

      assert_raise Postgrex.Error, ~r/completed_profiles/, fn ->
        raw_insert(coach_id(c), fighter_id(half))
      end

      coach_half = registered_user!()
      {:ok, _} = Coaches.update_profile(coach_half, %{"display_name" => "Half"})

      assert_raise Postgrex.Error, ~r/completed_profiles/, fn ->
        raw_insert(coach_id(coach_half), fighter_id(f))
      end
    end

    test "no self-coaching, enforced by the database too" do
      both = coach_user!() |> complete_fighter_onboarding!()

      assert_raise Postgrex.Error, ~r/no_self_coaching/, fn ->
        raw_insert(coach_id(both), fighter_id(both))
      end
    end

    test "an ended relationship can never be reactivated or rewritten", %{coach: c, fighter: f} do
      r = activate!(c, f)
      :ok = Coaching.end_relationship(c, :coach, r.id)
      ended = from(x in Relationship, where: x.id == ^r.id)

      for change <- [
            [status: :active, ended_at: nil, ended_by: nil],
            [ended_by: :fighter],
            [fighter_display_name_at_end: "Rewritten"]
          ] do
        assert_raise Postgrex.Error, ~r/ended_immutable/, fn ->
          Repo.update_all(ended, set: change)
        end
      end
    end

    test "only the end transition is allowed on an active relationship", %{coach: c, fighter: f} do
      r = activate!(c, f)
      other = fighter_user!()
      active = from(x in Relationship, where: x.id == ^r.id)

      for change <- [
            [fighter_profile_id: fighter_id(other)],
            [disclosure_version: "wider-v2"],
            [started_at: DateTime.add(r.started_at, -3600)]
          ] do
        assert_raise Postgrex.Error, ~r/end_only/, fn -> Repo.update_all(active, set: change) end
      end

      assert_raise Postgrex.Error, ~r/lifecycle/, fn ->
        Repo.update_all(active, set: [status: :ended])
      end
    end

    test "deleting a user removes their relationships (no orphan grants)", %{coach: c, fighter: f} do
      activate!(c, f)
      Repo.delete!(Repo.get!(Accounts.User, f.id))

      assert Repo.aggregate(Relationship, :count) == 0
      assert roster(c).entries == []
    end
  end

  describe "ending" do
    setup do
      coach = coach_user!("Coach Marek")
      fighter = fighter_user!()
      %{coach: coach, fighter: fighter, r: activate!(coach, fighter)}
    end

    test "the coach ends: coach access stops at once, the stub keeps the name snapshot", %{
      coach: c,
      fighter: f,
      r: r
    } do
      assert :ok = Coaching.end_relationship(c, :coach, r.id)

      assert {:error, :not_found} = Coaching.get_coach_relationship(c, r.id)
      assert roster(c).entries == []

      assert [stub] = roster(c, %{"status" => "ended"}).entries
      assert stub.relationship_id == r.id
      assert stub.status == :ended and stub.ended_by == :coach

      assert stub.fighter == nil and stub.disclosed_fields == [] and
               stub.disclosure_version == nil

      assert stub.fighter_display_name_at_end == "Alex K."

      # A later rename of the fighter does not reach the coach's history.
      {:ok, _} = Fighters.update_profile(f, %{"display_name" => "Renamed"})

      assert [%{fighter_display_name_at_end: "Alex K."}] =
               roster(c, %{"status" => "ended"}).entries

      assert [mine] = coaches(f, %{"status" => "ended"}).entries
      assert mine.coach == nil and mine.coach_display_name_at_end == "Coach Marek"
      assert coaches(f).entries == []
    end

    test "the fighter ends: the coach loses access immediately", %{coach: c, fighter: f, r: r} do
      assert {:ok, _} = Coaching.get_coach_relationship(c, r.id)
      assert :ok = Coaching.end_relationship(f, :fighter, r.id)
      assert {:error, :not_found} = Coaching.get_coach_relationship(c, r.id)
      assert [%{ended_by: :fighter}] = roster(c, %{"status" => "ended"}).entries
    end

    test "is idempotent and the first end is kept", %{coach: c, fighter: f, r: r} do
      :ok = Coaching.end_relationship(f, :fighter, r.id)
      first = Repo.get!(Relationship, r.id)

      assert :ok = Coaching.end_relationship(f, :fighter, r.id)
      assert :ok = Coaching.end_relationship(c, :coach, r.id)

      again = Repo.get!(Relationship, r.id)
      assert again.ended_at == first.ended_at and again.ended_by == :fighter
    end

    test "nobody else can end it, and unknown or malformed ids look the same", %{r: r} do
      stranger_coach = coach_user!()
      stranger_fighter = fighter_user!()
      both = coach_user!() |> complete_fighter_onboarding!()

      for {user, side} <- [
            {stranger_coach, :coach},
            {stranger_fighter, :fighter},
            {both, :coach},
            {both, :fighter},
            # A fighter-only user addressing it as coach, and the reverse.
            {stranger_fighter, :coach},
            {stranger_coach, :fighter}
          ] do
        assert {:error, :not_found} = Coaching.end_relationship(user, side, r.id)
      end

      assert Repo.get!(Relationship, r.id).status == :active

      for id <- [Ecto.UUID.generate(), "nope", "' OR 1=1 --"] do
        assert {:error, :not_found} = Coaching.end_relationship(stranger_coach, :coach, id)
      end
    end

    test "the wrong side of the right relationship cannot end it", %{coach: c, fighter: f, r: r} do
      # The coach is not the fighter of this relationship and vice versa.
      assert {:error, :not_found} = Coaching.end_relationship(c, :fighter, r.id)
      assert {:error, :not_found} = Coaching.end_relationship(f, :coach, r.id)
    end

    test "works while sharing is disabled, and enabling it revives nothing", %{
      coach: c,
      fighter: f,
      r: r
    } do
      set_sharing(enabled: false)
      assert :ok = Coaching.end_relationship(f, :fighter, r.id)

      set_sharing(enabled: true)
      assert {:error, :not_found} = Coaching.get_coach_relationship(c, r.id)
      assert roster(c).entries == []
    end
  end

  describe "coach reads" do
    setup do
      coach = coach_user!()
      fighter = fighter_user!()
      %{coach: coach, fighter: fighter, r: activate!(coach, fighter)}
    end

    test "only the coach's own active relationships", %{coach: c, r: r} do
      other_coach = coach_user!("Other")
      other = activate!(other_coach, fighter_user!())

      assert [%{relationship_id: id}] = roster(c).entries
      assert id == r.id
      assert {:error, :not_found} = Coaching.get_coach_relationship(c, other.id)
      assert {:error, :not_found} = Coaching.get_coach_relationship(other_coach, r.id)
      assert {:error, :not_found} = Coaching.get_coach_relationship(c, "not-a-uuid")
    end

    test "the projection is exactly the disclosed C1 + C2 fields", %{coach: c, r: r} do
      {:ok, entry} = Coaching.get_coach_relationship(c, r.id)

      assert entry.disclosed_fields ==
               ~w(display_name username country_code city experience_level stance amateur_bout_count)a

      assert Map.keys(entry.fighter) |> Enum.sort() ==
               Enum.sort(Fighters.coach_visible_fields())

      assert entry.fighter.display_name == "Alex K."
      assert entry.fighter.experience_level == :amateur
    end

    test "a withdrawn version discloses nothing", %{coach: c, r: r} do
      SimpleFit.LegalHelpers.build_registry!([
        %{
          document_id: "fighter-coach-disclosure",
          version: version(),
          scope: "basic_profile",
          status: "withdrawn"
        },
        %{
          document_id: "fighter-coach-disclosure",
          version: "fighter-coach-disclosure-test-2",
          scope: "basic_profile"
        },
        %{document_id: "coach-data-rules", version: data_rules_version()}
      ])

      set_sharing(
        disclosures: %{
          "fighter-coach-disclosure-test-2" => :basic_profile,
          version() => :basic_profile
        },
        current: "fighter-coach-disclosure-test-2"
      )

      {:ok, entry} = Coaching.get_coach_relationship(c, r.id)
      assert entry.disclosed_fields == []
      assert Enum.all?(Map.values(entry.fighter), &is_nil/1)
    end

    test "nothing while sharing is disabled", %{coach: c, r: r} do
      set_sharing(enabled: false)

      assert {:error, :not_found} = Coaching.list_coach_relationships(c, %{})
      assert {:error, :not_found} = Coaching.list_coach_relationships(c, %{"status" => "ended"})
      assert {:error, :not_found} = Coaching.get_coach_relationship(c, r.id)
    end

    test "require a completed coach profile", %{fighter: f, r: r} do
      half = registered_user!()
      {:ok, _} = Coaches.update_profile(half, %{"display_name" => "Half"})

      for user <- [f, half, registered_user!()] do
        assert {:error, :not_found} = Coaching.list_coach_relationships(user, %{})
        assert {:error, :not_found} = Coaching.get_coach_relationship(user, r.id)
      end
    end

    test "an empty roster is an empty page", %{} do
      assert %{entries: [], next_cursor: nil} = roster(coach_user!())
    end
  end

  describe "fighter reads" do
    test "the fighter's coaches with their public identity and the disclosed fields" do
      coach = coach_user!("Coach Marek")
      fighter = fighter_user!()
      r = activate!(coach, fighter)

      assert [entry] = coaches(fighter).entries
      assert entry.relationship_id == r.id
      assert entry.coach == %{display_name: "Coach Marek", brand_name: "Marek Boxing"}
      assert entry.disclosure_version == version()
      assert :display_name in entry.disclosed_fields
    end

    test "available while sharing is disabled; never someone else's" do
      coach = coach_user!()
      fighter = fighter_user!()
      activate!(coach, fighter)
      other = fighter_user!()
      set_sharing(enabled: false)

      assert [_] = coaches(fighter).entries
      assert coaches(other).entries == []
    end

    test "require a completed fighter profile" do
      assert {:error, :not_found} = Coaching.list_fighter_relationships(coach_user!(), %{})
      assert {:error, :not_found} = Coaching.list_fighter_relationships(registered_user!(), %{})
    end
  end

  describe "paging" do
    setup do
      coach = coach_user!()
      fighters = for _ <- 1..5, do: fighter_user!()
      for f <- fighters, do: activate!(coach, f)
      %{coach: coach, fighters: fighters}
    end

    test "walks every relationship exactly once, newest first", %{coach: c} do
      page1 = roster(c, %{"limit" => "2"})
      page2 = roster(c, %{"limit" => "2", "cursor" => page1.next_cursor})
      page3 = roster(c, %{"limit" => "2", "cursor" => page2.next_cursor})

      ids =
        Enum.flat_map([page1, page2, page3], fn p -> Enum.map(p.entries, & &1.relationship_id) end)

      assert length(ids) == 5 and length(Enum.uniq(ids)) == 5
      assert page3.next_cursor == nil

      started =
        Enum.flat_map([page1, page2, page3], fn p -> Enum.map(p.entries, & &1.started_at) end)

      assert started == Enum.sort(started, {:desc, DateTime})
    end

    test "rejects invalid params with field errors", %{coach: c} do
      for {params, field} <- [
            {%{"status" => "pending"}, :status},
            {%{"limit" => "0"}, :limit},
            {%{"limit" => "101"}, :limit},
            {%{"limit" => "many"}, :limit},
            {%{"cursor" => "garbage"}, :cursor},
            {%{"cursor" => Base.url_encode64("ended|1|#{Ecto.UUID.generate()}", padding: false)},
             :cursor}
          ] do
        assert {:error, %Ecto.Changeset{} = cs} = Coaching.list_coach_relationships(c, params)
        assert Keyword.has_key?(cs.errors, field), inspect(params)
      end
    end

    test "a cursor never reaches another coach's relationships", %{coach: c} do
      page = roster(c, %{"limit" => "1"})
      other = coach_user!("Other")
      activate!(other, fighter_user!())

      # A cursor is only a position: each page stays the caller's own.
      assert %{entries: []} = roster(coach_user!("Third"), %{"cursor" => page.next_cursor})
      mine = MapSet.new(roster(c, %{"limit" => "100"}).entries, & &1.relationship_id)

      for entry <- roster(other, %{"cursor" => page.next_cursor, "limit" => "100"}).entries,
          do: refute(MapSet.member?(mine, entry.relationship_id))
    end
  end

  describe "disclosure configuration" do
    test "parses version=scope pairs and fails closed on anything else" do
      assert Disclosure.parse!(nil) == %{}
      assert Disclosure.parse!(" ") == %{}

      assert Disclosure.parse!("legal-2026-11=basic_profile, v2=basic_profile") == %{
               "legal-2026-11" => :basic_profile,
               "v2" => :basic_profile
             }

      for bad <- [
            "v1",
            "v1=everything",
            "v1=basic_profile,v1=basic_profile",
            "bad id=basic_profile"
          ] do
        assert_raise ArgumentError, fn -> Disclosure.parse!(bad) end
      end
    end

    test "the default configuration offers nothing and keeps sharing off" do
      defaults = Application.get_env(:simple_fit, SimpleFit.Coaching)
      on_exit(fn -> Application.put_env(:simple_fit, SimpleFit.Coaching, defaults) end)

      Application.put_env(:simple_fit, SimpleFit.Coaching,
        access_enabled: false,
        disclosures: %{}
      )

      refute Coaching.access_enabled?()
      assert Disclosure.configured() == %{}
      assert Disclosure.fields(version()) == []
    end
  end
end
