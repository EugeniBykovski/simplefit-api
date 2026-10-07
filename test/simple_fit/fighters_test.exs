defmodule SimpleFit.FightersTest do
  use SimpleFit.DataCase, async: true

  alias SimpleFit.Accounts
  alias SimpleFit.Fighters
  alias SimpleFit.Fighters.FighterProfile
  alias SimpleFit.Repo
  alias SimpleFitWeb.ChangesetErrors

  @required %{
    "display_name" => "Yauheni B.",
    "username" => "yauheni",
    "country_code" => "PL",
    "city" => "Warsaw",
    "experience_level" => "competitive_amateur",
    "stance" => "orthodox"
  }

  setup do
    {:ok, user} = Accounts.register_user(:google, "fighter-#{System.unique_integer([:positive])}")
    %{user: user}
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
      assert {:ok, profile} = Fighters.update_profile(user, %{"display_name" => "Yauheni B."})

      assert profile.user_id == user.id
      assert profile.display_name == "Yauheni B."
      assert profile.username == nil
      assert profile.goals == []
      assert Fighters.onboarding_status(profile) == :in_progress
      assert Fighters.get_profile(user).id == profile.id
    end

    test "later saves add to the same profile and keep earlier fields", %{user: user} do
      {:ok, first} = Fighters.update_profile(user, %{"display_name" => "Yauheni B."})

      {:ok, second} =
        Fighters.update_profile(user, %{"stance" => "southpaw", "goals" => ["fitness"]})

      assert second.id == first.id
      assert second.display_name == "Yauheni B."
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
          "display_name" => "  Yauheni B.  ",
          "username" => " Yauheni_B ",
          "country_code" => "pl",
          "city" => "",
          "current_weight_kg" => 73.84
        })

      assert profile.display_name == "Yauheni B."
      assert profile.username == "yauheni_b"
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
               Fighters.update_profile(user, %{"city" => "Kraków", "height_cm" => 20})

      assert Fighters.get_profile(user).city == "Warsaw"
    end

    test "rejects values outside the approved vocabularies and ranges", %{user: user} do
      result =
        Fighters.update_profile(user, %{
          "experience_level" => "legend",
          "stance" => "wrong-footed",
          "goals" => ["fitness", "world_title"],
          "weight_class" => "minus_100",
          "username" => "9lives",
          "country_code" => "POL",
          "display_name" => String.duplicate("x", 81),
          "current_weight_kg" => 12,
          "height_cm" => 300
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

    test "rejects a repeated goal", %{user: user} do
      assert %{"goals" => [_]} =
               field_codes(Fighters.update_profile(user, %{"goals" => ["fitness", "fitness"]}))
    end

    test "a username another fighter holds is already_exists, case-insensitively", %{user: user} do
      {:ok, other} = Accounts.register_user(:email, "other@example.com")
      {:ok, _} = Fighters.update_profile(other, %{"username" => "yauheni"})

      assert field_codes(Fighters.update_profile(user, %{"username" => "Yauheni"})) ==
               %{"username" => ["already_exists"]}
    end

    test "records a bout count only for competitive amateurs", %{user: user} do
      assert %{"bout_count" => ["invalid_choice"]} =
               field_codes(
                 Fighters.update_profile(user, %{
                   "experience_level" => "amateur",
                   "bout_count" => 3
                 })
               )

      {:ok, profile} =
        Fighters.update_profile(user, %{
          "experience_level" => "competitive_amateur",
          "bout_count" => 14
        })

      assert profile.bout_count == 14

      {:ok, profile} = Fighters.update_profile(user, %{"experience_level" => "professional"})
      assert profile.bout_count == nil
    end

    test "an event name for the next fight needs its date", %{user: user} do
      assert %{"next_fight_on" => ["required"]} =
               field_codes(Fighters.update_profile(user, %{"next_fight_name" => "Warsaw Cup"}))

      {:ok, profile} =
        Fighters.update_profile(user, %{
          "next_fight_on" => "2026-11-03",
          "next_fight_name" => "Warsaw Cup"
        })

      assert profile.next_fight_on == ~D[2026-11-03]
    end

    test "never accepts the completion marker from a client", %{user: user} do
      {:ok, profile} =
        Fighters.update_profile(user, %{"onboarding_completed_at" => "2026-10-08T10:00:00Z"})

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

    test "the database rejects a completed profile without its requirements", %{user: user} do
      {:ok, profile} = Fighters.update_profile(user, %{"city" => "Warsaw"})

      assert_raise Ecto.ConstraintError, ~r/completed_onboarding_requirements/, fn ->
        profile
        |> Ecto.Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
        |> Repo.update()
      end
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
        "display_name" => "Yauheni B.",
        "city" => "Warsaw",
        "current_weight_kg" => 73.8
      })

    output = inspect(profile)

    for value <- ["Yauheni", "Warsaw", "73.8"], do: refute(output =~ value)
  end
end
