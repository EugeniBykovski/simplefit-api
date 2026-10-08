defmodule SimpleFit.FightersTest do
  use SimpleFit.DataCase, async: true

  import SimpleFit.AccountRegistrationHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Fighters
  alias SimpleFit.Fighters.{CountryCodes, FighterProfile}
  alias SimpleFit.Repo
  alias SimpleFitWeb.ChangesetErrors

  @required %{
    "display_name" => "Alex K.",
    "username" => "fighter_one",
    "country_code" => "PL",
    "city" => "Warsaw",
    "experience_level" => "competitive_amateur",
    "stance" => "orthodox"
  }

  setup do
    {:ok, user} = Accounts.register_user(:google, "fighter-#{System.unique_integer([:positive])}")
    # Fighter completion requires completed account registration (ADR 0016);
    # the "account registration" describe below covers a user without it.
    %{user: complete_account_registration!(user)}
  end

  defp field_codes({:error, changeset}), do: ChangesetErrors.details(changeset).field_codes

  describe "a user without a fighter profile" do
    test "creating a user creates no fighter profile", %{user: user} do
      assert Fighters.get_profile(user) == nil
      assert Repo.aggregate(FighterProfile, :count) == 0
    end

    test "is not_started with every requirement missing", %{user: user} do
      profile = Fighters.get_profile(user)

      assert Fighters.onboarding_status(profile) == :not_started

      assert Fighters.missing_requirements(profile) ==
               [:display_name, :username, :country_code, :city, :experience_level, :stance]
    end
  end

  describe "update_profile/2 (saving progress)" do
    test "the first save creates an in-progress profile with only the given fields", %{user: user} do
      assert {:ok, profile} = Fighters.update_profile(user, %{"display_name" => "Alex K."})

      assert profile.user_id == user.id
      assert profile.display_name == "Alex K."
      assert profile.username == nil
      assert profile.goals == []
      assert Fighters.onboarding_status(profile) == :in_progress
      assert Fighters.get_profile(user).id == profile.id
    end

    test "a save with nothing to persist creates no profile", %{user: user} do
      for attrs <- [
            %{},
            %{"goals" => []},
            %{"city" => nil},
            %{"unknown" => "x"},
            %{"city" => "  "}
          ] do
        assert {:ok, nil} = Fighters.update_profile(user, attrs)
        assert Fighters.get_profile(user) == nil
        assert Fighters.onboarding_status(Fighters.get_profile(user)) == :not_started
      end

      assert Repo.aggregate(FighterProfile, :count) == 0
    end

    test "a save with nothing to persist returns an existing profile unchanged", %{user: user} do
      {:ok, created} = Fighters.update_profile(user, %{"city" => "Warsaw"})
      assert {:ok, same} = Fighters.update_profile(user, %{})

      assert same.id == created.id and same.city == "Warsaw"
    end

    test "later saves add to the same profile and keep earlier fields", %{user: user} do
      {:ok, first} = Fighters.update_profile(user, %{"display_name" => "Alex K."})

      {:ok, second} =
        Fighters.update_profile(user, %{"stance" => "southpaw", "goals" => ["fitness"]})

      assert second.id == first.id
      assert second.display_name == "Alex K."
      assert second.stance == :southpaw
      assert second.goals == [:fitness]
      assert Repo.aggregate(FighterProfile, :count) == 1
    end

    test "null clears an optional field and goals", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, %{"city" => "Warsaw", "goals" => ["fitness"]})
      {:ok, profile} = Fighters.update_profile(user, %{"city" => nil, "goals" => nil})

      assert profile.city == nil
      assert profile.goals == []
    end

    test "canonicalises text: trimmed, lowercase username, uppercase country", %{user: user} do
      {:ok, profile} =
        Fighters.update_profile(user, %{
          "display_name" => "  Alex K.  ",
          "username" => " Fighter_One ",
          "country_code" => "pl",
          "city" => "",
          "current_weight_kg" => 73.8
        })

      assert profile.display_name == "Alex K."
      assert profile.username == "fighter_one"
      assert profile.country_code == "PL"
      assert profile.city == nil
      assert Decimal.equal?(profile.current_weight_kg, Decimal.new("73.8"))
    end

    test "an invalid first save creates no profile", %{user: user} do
      assert {:error, %Ecto.Changeset{}} =
               Fighters.update_profile(user, %{"stance" => "wrong-footed"})

      assert Fighters.get_profile(user) == nil
    end

    test "an invalid save changes nothing", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, %{"city" => "Warsaw"})

      assert {:error, _} =
               Fighters.update_profile(user, %{"city" => "Kraków", "height_cm" => 0})

      assert Fighters.get_profile(user).city == "Warsaw"
    end

    test "rejects values outside the approved vocabularies and ranges", %{user: user} do
      result =
        Fighters.update_profile(user, %{
          "experience_level" => "legend",
          "stance" => "wrong-footed",
          "goals" => ["fitness", "world_title"],
          "weight_class" => "minus_100",
          "username" => "_lead",
          "country_code" => "POL",
          "display_name" => String.duplicate("x", 81),
          "current_weight_kg" => 0,
          "height_cm" => 1000
        })

      assert field_codes(result) == %{
               "experience_level" => ["invalid_choice"],
               "stance" => ["invalid_choice"],
               "goals" => ["invalid_choice"],
               "weight_class" => ["invalid_choice"],
               "username" => ["invalid_format"],
               "country_code" => ["invalid_format"],
               "display_name" => ["too_long"],
               "current_weight_kg" => ["out_of_range"],
               "height_cm" => ["out_of_range"]
             }
    end

    test "measurement bounds are technical, not boxing policy", %{user: user} do
      {:ok, profile} =
        Fighters.update_profile(user, %{"current_weight_kg" => 150.0, "height_cm" => 205})

      assert profile.height_cm == 205
      assert Decimal.equal?(profile.current_weight_kg, Decimal.new("150.0"))

      assert %{"current_weight_kg" => ["out_of_range"], "height_cm" => ["out_of_range"]} =
               field_codes(
                 Fighters.update_profile(user, %{"current_weight_kg" => -1, "height_cm" => 0})
               )
    end

    test "username policy: 3-30 characters, letters, digits and underscores, alphanumeric ends",
         %{user: user} do
      for valid <- ["abc", "9lives", "a_b", String.duplicate("a", 30)] do
        assert {:ok, %FighterProfile{username: ^valid}} =
                 Fighters.update_profile(user, %{"username" => valid})
      end

      for invalid <- [
            "ab",
            String.duplicate("a", 31),
            "_lead",
            "trail_",
            "has-dash",
            "dot.ted",
            "ünï"
          ] do
        assert %{"username" => ["invalid_format"]} =
                 field_codes(Fighters.update_profile(user, %{"username" => invalid}))
      end
    end

    test "country is an assigned ISO 3166-1 alpha-2 code, trimmed and uppercased", %{user: user} do
      for {input, stored} <- [
            {"pl", "PL"},
            {" de ", "DE"},
            {"JP", "JP"},
            {"br", "BR"},
            {"NG", "NG"}
          ] do
        assert {:ok, %FighterProfile{country_code: ^stored}} =
                 Fighters.update_profile(user, %{"country_code" => input})
      end

      for unassigned <- ["ZZ", "XK", "UK", "EU"] do
        assert %{"country_code" => ["invalid_choice"]} =
                 field_codes(Fighters.update_profile(user, %{"country_code" => unassigned}))
      end

      for malformed <- ["P", "POL", "P1"] do
        assert %{"country_code" => ["invalid_format"]} =
                 field_codes(Fighters.update_profile(user, %{"country_code" => malformed}))
      end

      {:ok, profile} = Fighters.update_profile(user, %{"country_code" => nil})
      assert profile.country_code == nil
    end

    test "the country allowlist holds the 249 assigned codes" do
      assert CountryCodes.count() == 249
    end

    test "rejects a repeated goal", %{user: user} do
      assert %{"goals" => [_]} =
               field_codes(Fighters.update_profile(user, %{"goals" => ["fitness", "fitness"]}))
    end

    test "a username another fighter holds is already_exists, case-insensitively", %{user: user} do
      {:ok, other} = Accounts.register_user(:email, "other@example.com")
      {:ok, _} = Fighters.update_profile(other, %{"username" => "fighter_one"})

      assert field_codes(Fighters.update_profile(user, %{"username" => "Fighter_One"})) ==
               %{"username" => ["already_exists"]}
    end

    test "the amateur bout count is kept when the experience level changes", %{user: user} do
      {:ok, profile} =
        Fighters.update_profile(user, %{
          "experience_level" => "competitive_amateur",
          "amateur_bout_count" => 14
        })

      assert profile.amateur_bout_count == 14

      {:ok, profile} = Fighters.update_profile(user, %{"experience_level" => "professional"})
      assert profile.amateur_bout_count == 14

      {:ok, profile} = Fighters.update_profile(user, %{"amateur_bout_count" => 1200})
      assert profile.amateur_bout_count == 1200

      assert %{"amateur_bout_count" => ["out_of_range"]} =
               field_codes(Fighters.update_profile(user, %{"amateur_bout_count" => -1}))
    end

    test "weight accepts at most one decimal place and is never rounded", %{user: user} do
      for {input, stored} <- [{81, "81"}, {81.2, "81.2"}, {"81.2", "81.2"}] do
        assert {:ok, profile} = Fighters.update_profile(user, %{"current_weight_kg" => input})
        assert Decimal.equal?(profile.current_weight_kg, Decimal.new(stored))
      end

      for input <- [81.27, "81.27", 81.205] do
        assert %{"current_weight_kg" => ["invalid_format"]} =
                 field_codes(Fighters.update_profile(user, %{"current_weight_kg" => input}))
      end

      assert Decimal.equal?(Fighters.get_profile(user).current_weight_kg, Decimal.new("81.2"))
    end

    test "next fight date and event name are saved independently", %{user: user} do
      {:ok, profile} = Fighters.update_profile(user, %{"next_fight_name" => "Warsaw Cup"})
      assert profile.next_fight_name == "Warsaw Cup" and profile.next_fight_on == nil

      {:ok, profile} =
        Fighters.update_profile(user, %{"next_fight_name" => nil, "next_fight_on" => "2026-11-03"})

      assert profile.next_fight_on == ~D[2026-11-03] and profile.next_fight_name == nil

      {:ok, profile} = Fighters.update_profile(user, %{"next_fight_name" => "Warsaw Cup"})
      assert profile.next_fight_on == ~D[2026-11-03] and profile.next_fight_name == "Warsaw Cup"

      {:ok, profile} =
        Fighters.update_profile(user, %{"next_fight_on" => nil, "next_fight_name" => nil})

      assert profile.next_fight_on == nil and profile.next_fight_name == nil
    end

    test "never accepts the completion marker from a client", %{user: user} do
      marker = %{"onboarding_completed_at" => "2026-10-08T10:00:00Z"}

      assert {:ok, nil} = Fighters.update_profile(user, marker)
      assert Fighters.get_profile(user) == nil

      {:ok, profile} = Fighters.update_profile(user, Map.put(marker, "city", "Warsaw"))
      assert profile.onboarding_completed_at == nil
      assert Fighters.onboarding_status(profile) == :in_progress
    end

    test "concurrent first saves converge on one profile", %{user: user} do
      tasks =
        for field <- ["Warsaw", "Kraków"] do
          Task.async(fn -> Fighters.update_profile(user, %{"city" => field}) end)
        end

      assert [{:ok, a}, {:ok, b}] = Task.await_many(tasks)
      assert a.id == b.id
      assert Repo.aggregate(FighterProfile, :count) == 1
    end
  end

  describe "complete_onboarding/1" do
    test "fails without a profile, lists every requirement and creates nothing", %{user: user} do
      result = Fighters.complete_onboarding(user)

      assert field_codes(result) ==
               Map.new(@required, fn {field, _} -> {field, ["required"]} end)

      assert Fighters.get_profile(user) == nil
    end

    test "fails while a requirement is missing and changes nothing", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, Map.delete(@required, "city"))

      assert field_codes(Fighters.complete_onboarding(user)) == %{"city" => ["required"]}

      profile = Fighters.get_profile(user)
      assert profile.onboarding_completed_at == nil
      assert Fighters.missing_requirements(profile) == [:city]
    end

    test "succeeds once every requirement is present and persists the completion", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, @required)

      assert {:ok, %FighterProfile{onboarding_completed_at: %DateTime{} = at}} =
               Fighters.complete_onboarding(user)

      profile = Fighters.get_profile(user)
      assert profile.onboarding_completed_at == at
      assert Fighters.onboarding_status(profile) == :completed
      assert Fighters.missing_requirements(profile) == []
    end

    test "optional and skippable fields are not required", %{user: user} do
      {:ok, profile} = Fighters.update_profile(user, @required)

      assert profile.goals == [] and profile.weight_class == nil and profile.next_fight_on == nil
      assert {:ok, _} = Fighters.complete_onboarding(user)
    end

    test "completing again keeps the original completion time", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, @required)
      {:ok, first} = Fighters.complete_onboarding(user)
      {:ok, again} = Fighters.complete_onboarding(user)

      assert again.onboarding_completed_at == first.onboarding_completed_at
    end

    test "a completed profile stays editable but cannot lose a requirement", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, @required)
      {:ok, _} = Fighters.complete_onboarding(user)

      {:ok, profile} =
        Fighters.update_profile(user, %{"city" => "Kraków", "goals" => ["fitness"]})

      assert profile.city == "Kraków"
      assert Fighters.onboarding_status(profile) == :completed

      assert field_codes(Fighters.update_profile(user, %{"city" => nil})) ==
               %{"city" => ["required"]}

      assert Fighters.get_profile(user).city == "Kraków"
    end

    test "completion is blocked without a country", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, Map.delete(@required, "country_code"))
      assert field_codes(Fighters.complete_onboarding(user)) == %{"country_code" => ["required"]}
    end

    test "the database keeps the completion time immutable", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, @required)
      {:ok, completed} = Fighters.complete_onboarding(user)

      for change <- [nil, DateTime.add(completed.onboarding_completed_at, 60)] do
        assert_raise Ecto.ConstraintError, ~r/onboarding_completed_at_immutable/, fn ->
          completed
          |> Ecto.Changeset.change(onboarding_completed_at: change)
          |> Repo.update()
        end
      end
    end

    test "the database rejects a completed profile without its requirements", %{user: user} do
      {:ok, profile} = Fighters.update_profile(user, %{"city" => "Warsaw"})

      assert_raise Ecto.ConstraintError, ~r/completed_onboarding_requirements/, fn ->
        profile
        |> Ecto.Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
        |> Repo.update()
      end
    end
  end

  describe "account registration (cross-context invariant, ADR 0016)" do
    setup do
      {:ok, unregistered} = Accounts.register_user(:email, "unregistered@example.com")
      %{unregistered: unregistered}
    end

    test "fighter progress can be saved before account registration", %{unregistered: user} do
      assert {:ok, profile} = Fighters.update_profile(user, @required)
      assert Fighters.onboarding_status(profile) == :in_progress
    end

    test "completion is blocked until account registration is complete", %{unregistered: user} do
      {:ok, _} = Fighters.update_profile(user, @required)

      assert field_codes(Fighters.complete_onboarding(user)) == %{
               "account_registration" => ["required"]
             }

      assert Fighters.get_profile(user).onboarding_completed_at == nil

      complete_account_registration!(user)

      assert {:ok, %FighterProfile{onboarding_completed_at: %DateTime{}}} =
               Fighters.complete_onboarding(user)
    end

    test "missing fighter fields and account registration are reported together", %{
      unregistered: user
    } do
      {:ok, _} = Fighters.update_profile(user, Map.delete(@required, "city"))

      assert field_codes(Fighters.complete_onboarding(user)) ==
               %{"city" => ["required"], "account_registration" => ["required"]}
    end
  end

  describe "ownership" do
    test "each user only ever sees and changes their own profile", %{user: user} do
      {:ok, other} = Accounts.register_user(:email, "someone@example.com")
      {:ok, mine} = Fighters.update_profile(user, %{"city" => "Warsaw"})

      assert Fighters.get_profile(other) == nil
      {:ok, theirs} = Fighters.update_profile(other, %{"city" => "Kraków"})

      refute theirs.id == mine.id
      assert Fighters.get_profile(user).city == "Warsaw"
    end

    test "deleting the user deletes the profile", %{user: user} do
      {:ok, _} = Fighters.update_profile(user, %{"city" => "Warsaw"})
      Repo.delete!(user)

      assert Repo.aggregate(FighterProfile, :count) == 0
    end
  end

  test "personal data is redacted from inspect output", %{user: user} do
    {:ok, profile} =
      Fighters.update_profile(user, %{
        "display_name" => "Alex K.",
        "city" => "Warsaw",
        "current_weight_kg" => 73.8
      })

    output = inspect(profile)

    for value <- ["Fighter_One", "Warsaw", "73.8"], do: refute(output =~ value)
  end
end
