defmodule SimpleFit.CoachesTest do
  use SimpleFit.DataCase, async: true

  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Coaches
  alias SimpleFit.Coaches.CoachProfile
  alias SimpleFit.Fighters
  alias SimpleFit.Fighters.FighterProfile
  alias SimpleFit.Repo
  alias SimpleFitWeb.ChangesetErrors

  @required %{
    "display_name" => "Coach Marek",
    "country_code" => "PL",
    "city" => "Warsaw",
    "coaching_formats" => ["personal_training"]
  }

  @requirements ~w(display_name country_code city coaching_formats)

  setup do
    {:ok, user} = Accounts.register_user(:google, "coach-#{System.unique_integer([:positive])}")
    # Most tests are about the coach profile itself; registration is complete
    # so completion is reachable. The "account registration" describe below
    # covers a user without it.
    %{user: complete_account_registration!(user)}
  end

  defp field_codes({:error, %Ecto.Changeset{} = changeset}),
    do: ChangesetErrors.details(changeset).field_codes

  defp complete!(user) do
    {:ok, _} = Coaches.update_profile(user, @required)
    {:ok, profile} = Coaches.complete_onboarding(user)
    profile
  end

  defp count, do: Repo.aggregate(CoachProfile, :count)

  describe "a user without a coach profile" do
    test "creating a user creates no coach profile", %{user: user} do
      assert Coaches.get_profile(user) == nil
      assert count() == 0
    end

    test "is not_started with every requirement missing", %{user: user} do
      assert Coaches.onboarding_status(nil) == :not_started

      assert Coaches.missing_requirements(Coaches.get_profile(user)) ==
               Enum.map(@requirements, &String.to_atom/1)
    end
  end

  describe "update_profile/2 (saving progress)" do
    test "the first save creates an in-progress profile with only the given fields", %{user: user} do
      {:ok, profile} = Coaches.update_profile(user, %{"bio" => "Footwork first."})

      assert Coaches.onboarding_status(profile) == :in_progress
      assert profile.bio == "Footwork first."
      assert profile.display_name == nil
      assert profile.languages == []
      assert profile.coaching_formats == []

      assert Coaches.missing_requirements(profile) == [
               :display_name,
               :country_code,
               :city,
               :coaching_formats
             ]
    end

    test "a save with nothing to persist creates no profile", %{user: user} do
      for attrs <- [
            %{},
            %{"languages" => []},
            %{"coaching_formats" => nil},
            %{"bio" => nil},
            %{"brand_name" => "   "}
          ] do
        assert {:ok, nil} = Coaches.update_profile(user, attrs)
      end

      assert count() == 0
    end

    test "a save with nothing to persist returns an existing profile unchanged", %{user: user} do
      {:ok, first} = Coaches.update_profile(user, %{"city" => "Warsaw"})
      {:ok, again} = Coaches.update_profile(user, %{})
      {:ok, same} = Coaches.update_profile(user, %{"city" => "Warsaw"})

      assert again == first
      assert same.updated_at == first.updated_at
      assert Coaches.onboarding_status(same) == :in_progress
    end

    test "later saves add to the same profile and keep earlier fields", %{user: user} do
      {:ok, first} = Coaches.update_profile(user, %{"display_name" => "Coach Marek"})

      {:ok, second} =
        Coaches.update_profile(user, %{"city" => "Warsaw", "languages" => ["pl", "en"]})

      assert second.id == first.id
      assert second.display_name == "Coach Marek"
      assert second.languages == [:pl, :en]
      assert count() == 1
    end

    test "every approved value of every selection is accepted, in the given order", %{user: user} do
      {:ok, profile} =
        Coaches.update_profile(user, %{
          "languages" => ["uk", "be", "ru", "pl", "en"],
          "coaching_formats" => [
            "fight_camps",
            "online_coaching",
            "group_coaching",
            "personal_training"
          ],
          "competition_levels" => ["professional", "amateur"]
        })

      assert profile.languages == [:uk, :be, :ru, :pl, :en]

      assert profile.coaching_formats == [
               :fight_camps,
               :online_coaching,
               :group_coaching,
               :personal_training
             ]

      assert profile.competition_levels == [:professional, :amateur]
      assert Coaches.get_profile(user) == profile
    end

    test "null, empty text and [] clear optional fields; omitted fields are unchanged", %{
      user: user
    } do
      {:ok, _} =
        Coaches.update_profile(user, %{
          "brand_name" => "Marek Boxing",
          "bio" => "Footwork first.",
          "languages" => ["pl"],
          "competition_levels" => ["amateur"],
          "city" => "Warsaw"
        })

      {:ok, profile} =
        Coaches.update_profile(user, %{
          "brand_name" => nil,
          "bio" => "  ",
          "languages" => nil,
          "competition_levels" => []
        })

      assert profile.brand_name == nil
      assert profile.bio == nil
      assert profile.languages == []
      assert profile.competition_levels == []
      assert profile.city == "Warsaw"
    end

    test "canonicalises text: trimmed, uppercase country", %{user: user} do
      {:ok, profile} =
        Coaches.update_profile(user, %{
          "display_name" => "  Coach Marek  ",
          "brand_name" => " Marek Boxing ",
          "country_code" => " pl ",
          "city" => " Kraków ",
          "bio" => "\n Line one.\nLine two. \n"
        })

      assert profile.display_name == "Coach Marek"
      assert profile.brand_name == "Marek Boxing"
      assert profile.country_code == "PL"
      assert profile.city == "Kraków"
      assert profile.bio == "Line one.\nLine two."
    end

    test "an invalid first save creates no profile", %{user: user} do
      assert {:error, _} =
               Coaches.update_profile(user, %{"city" => "Warsaw", "coaching_formats" => ["yoga"]})

      assert count() == 0
    end

    test "an invalid save changes nothing", %{user: user} do
      {:ok, _} = Coaches.update_profile(user, %{"city" => "Warsaw", "languages" => ["pl"]})

      assert {:error, _} =
               Coaches.update_profile(user, %{"city" => "Kraków", "languages" => ["de"]})

      profile = Coaches.get_profile(user)
      assert profile.city == "Warsaw"
      assert profile.languages == [:pl]
    end

    test "rejects values outside the approved vocabularies", %{user: user} do
      result =
        Coaches.update_profile(user, %{
          "languages" => ["en", "de"],
          "coaching_formats" => ["personal_training", "strength_conditioning"],
          "competition_levels" => ["fitness"]
        })

      assert field_codes(result) == %{
               "languages" => ["invalid_choice"],
               "coaching_formats" => ["invalid_choice"],
               "competition_levels" => ["invalid_choice"]
             }
    end

    test "formats, levels and audiences never share a vocabulary", %{user: user} do
      for {field, value} <- [
            {"coaching_formats", "amateur"},
            {"coaching_formats", "in_person"},
            {"competition_levels", "personal_training"},
            {"competition_levels", "womens"},
            {"competition_levels", "youth"},
            {"coaching_formats", "independent"}
          ] do
        assert field_codes(Coaches.update_profile(user, %{field => [value]})) ==
                 %{field => ["invalid_choice"]},
               "#{field}: #{value}"
      end

      assert count() == 0
    end

    test "rejects repeated values instead of dropping them", %{user: user} do
      result =
        Coaches.update_profile(user, %{
          "languages" => ["pl", "pl"],
          "coaching_formats" => ["fight_camps", "fight_camps"],
          "competition_levels" => ["amateur", "amateur"]
        })

      assert field_codes(result) == %{
               "languages" => ["invalid"],
               "coaching_formats" => ["invalid"],
               "competition_levels" => ["invalid"]
             }
    end

    test "rejects a selection that is not a list", %{user: user} do
      assert field_codes(Coaches.update_profile(user, %{"languages" => "pl"})) ==
               %{"languages" => ["invalid_type"]}
    end

    test "rejects text that is not a string", %{user: user} do
      assert field_codes(Coaches.update_profile(user, %{"display_name" => 42})) ==
               %{"display_name" => ["invalid_type"]}
    end

    test "length limits count characters, after trimming", %{user: user} do
      at_limit = %{
        "display_name" => String.duplicate("ż", 60),
        "brand_name" => String.duplicate("b", 80),
        "city" => String.duplicate("c", 80),
        "bio" => String.duplicate("é", 500)
      }

      {:ok, profile} =
        Coaches.update_profile(user, Map.new(at_limit, fn {k, v} -> {k, " #{v} "} end))

      assert String.length(profile.display_name) == 60
      assert String.length(profile.bio) == 500

      over = Map.new(at_limit, fn {k, v} -> {k, v <> "x"} end)

      assert field_codes(Coaches.update_profile(user, over)) == %{
               "display_name" => ["too_long"],
               "brand_name" => ["too_long"],
               "city" => ["too_long"],
               "bio" => ["too_long"]
             }
    end

    test "lengths count code points, as the database does", %{user: user} do
      # "é" as e + combining acute accent: 1 grapheme, 2 code points.
      decomposed = String.duplicate("é", 31)

      assert field_codes(Coaches.update_profile(user, %{"display_name" => decomposed})) ==
               %{"display_name" => ["too_long"]}
    end

    test "rejects control characters; the bio may contain line breaks", %{user: user} do
      result =
        Coaches.update_profile(user, %{
          "display_name" => "Coach\u0000Marek",
          "brand_name" => "Marek\nBoxing",
          "city" => "War\u0007saw",
          "bio" => "Tab\there"
        })

      assert field_codes(result) == %{
               "display_name" => ["invalid_format"],
               "brand_name" => ["invalid_format"],
               "city" => ["invalid_format"],
               "bio" => ["invalid_format"]
             }

      assert {:ok, %{bio: "One\r\nTwo"}} = Coaches.update_profile(user, %{"bio" => "One\r\nTwo"})
    end

    test "country is an assigned ISO 3166-1 alpha-2 code (the fighter profile list)", %{
      user: user
    } do
      assert field_codes(Coaches.update_profile(user, %{"country_code" => "XX"})) ==
               %{"country_code" => ["invalid_choice"]}

      assert field_codes(Coaches.update_profile(user, %{"country_code" => "POL"})) ==
               %{"country_code" => ["invalid_format"]}

      assert {:ok, %{country_code: "UA"}} =
               Coaches.update_profile(user, %{"country_code" => "ua"})
    end

    test "rejects the completion marker, ids, owner and unknown fields, saving nothing", %{
      user: user
    } do
      {:ok, other} =
        Accounts.register_user(:google, "other-#{System.unique_integer([:positive])}")

      result =
        Coaches.update_profile(user, %{
          "city" => "Warsaw",
          "onboarding_completed_at" => "2026-10-13T10:00:00Z",
          "user_id" => other.id,
          "id" => Ecto.UUID.generate(),
          "nickname" => "Iron"
        })

      assert field_codes(result) == %{
               "id" => ["invalid"],
               "nickname" => ["invalid"],
               "onboarding_completed_at" => ["invalid"],
               "user_id" => ["invalid"]
             }

      assert Coaches.get_profile(user) == nil
      assert Coaches.get_profile(other) == nil
    end

    test "unknown keys are reported as given, never turned into atoms", %{user: user} do
      key = "unknown_#{System.unique_integer([:positive])}"
      assert field_codes(Coaches.update_profile(user, %{key => 1})) == %{key => ["invalid"]}
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "concurrent first saves converge on one profile", %{user: user} do
      tasks =
        for city <- ["Warsaw", "Kraków"] do
          Task.async(fn -> Coaches.update_profile(user, %{"city" => city}) end)
        end

      assert [{:ok, a}, {:ok, b}] = Task.await_many(tasks)
      assert a.id == b.id
      assert count() == 1
    end
  end

  describe "complete_onboarding/1" do
    test "fails without a profile, lists every requirement and creates nothing", %{user: user} do
      assert field_codes(Coaches.complete_onboarding(user)) ==
               Map.new(@requirements, &{&1, ["required"]})

      assert count() == 0
    end

    test "fails while a requirement is missing and changes nothing", %{user: user} do
      {:ok, _} = Coaches.update_profile(user, Map.delete(@required, "coaching_formats"))

      assert field_codes(Coaches.complete_onboarding(user)) == %{
               "coaching_formats" => ["required"]
             }

      profile = Coaches.get_profile(user)
      assert profile.onboarding_completed_at == nil
      assert Coaches.missing_requirements(profile) == [:coaching_formats]
    end

    test "having every required field is not completion", %{user: user} do
      {:ok, profile} = Coaches.update_profile(user, @required)

      assert Coaches.missing_requirements(profile) == []
      assert Coaches.onboarding_status(profile) == :in_progress
      assert profile.onboarding_completed_at == nil
    end

    test "succeeds once every requirement is present and persists the completion", %{user: user} do
      {:ok, _} = Coaches.update_profile(user, @required)
      {:ok, profile} = Coaches.complete_onboarding(user)

      assert Coaches.onboarding_status(profile) == :completed
      assert %DateTime{} = profile.onboarding_completed_at
      assert Coaches.get_profile(user).onboarding_completed_at == profile.onboarding_completed_at
    end

    test "optional fields are not required", %{user: user} do
      {:ok, _} = Coaches.update_profile(user, @required)
      assert {:ok, profile} = Coaches.complete_onboarding(user)
      assert profile.brand_name == nil and profile.bio == nil
      assert profile.languages == [] and profile.competition_levels == []
    end

    test "completing again keeps the original completion time", %{user: user} do
      first = complete!(user)
      {:ok, again} = Coaches.complete_onboarding(user)
      assert again.onboarding_completed_at == first.onboarding_completed_at
    end

    test "a completed profile stays editable but cannot lose a requirement", %{user: user} do
      first = complete!(user)

      {:ok, updated} =
        Coaches.update_profile(user, %{
          "display_name" => "Marek K.",
          "brand_name" => "Marek Boxing",
          "coaching_formats" => ["online_coaching"],
          "languages" => ["pl"]
        })

      assert Coaches.onboarding_status(updated) == :completed
      assert updated.onboarding_completed_at == first.onboarding_completed_at

      for {field, value} <- [
            {"display_name", nil},
            {"display_name", " "},
            {"country_code", nil},
            {"city", ""},
            {"coaching_formats", []},
            {"coaching_formats", nil}
          ] do
        assert field_codes(Coaches.update_profile(user, %{field => value})) ==
                 %{field => ["required"]},
               "#{field}: #{inspect(value)}"
      end

      # Optional fields still clear after completion.
      assert {:ok, %{brand_name: nil, languages: []}} =
               Coaches.update_profile(user, %{"brand_name" => nil, "languages" => []})

      assert Coaches.get_profile(user).display_name == "Marek K."
    end

    test "a failed completion can be retried once the profile is complete", %{user: user} do
      {:ok, _} = Coaches.update_profile(user, Map.delete(@required, "city"))
      assert {:error, _} = Coaches.complete_onboarding(user)

      {:ok, _} = Coaches.update_profile(user, %{"city" => "Warsaw"})
      assert {:ok, %{onboarding_completed_at: %DateTime{}}} = Coaches.complete_onboarding(user)
    end

    test "the database keeps the completion time immutable", %{user: user} do
      profile = complete!(user)

      assert_raise Postgrex.Error, ~r/onboarding completion is immutable/, fn ->
        Repo.query!(
          "UPDATE coach_profiles SET onboarding_completed_at = now() - interval '1 day' WHERE id = $1",
          [Ecto.UUID.dump!(profile.id)]
        )
      end

      assert Coaches.get_profile(user).onboarding_completed_at == profile.onboarding_completed_at
    end

    test "the database rejects a completed profile without its requirements", %{user: user} do
      profile = complete!(user)

      assert_raise Postgrex.Error, ~r/completed_onboarding_requirements/, fn ->
        Repo.query!("UPDATE coach_profiles SET coaching_formats = '{}' WHERE id = $1", [
          Ecto.UUID.dump!(profile.id)
        ])
      end
    end

    test "the database rejects text beyond the length limits", %{user: user} do
      {:ok, profile} = Coaches.update_profile(user, %{"city" => "Warsaw"})

      assert_raise Postgrex.Error, ~r/display_name_length/, fn ->
        Repo.query!("UPDATE coach_profiles SET display_name = $2 WHERE id = $1", [
          Ecto.UUID.dump!(profile.id),
          String.duplicate("x", 61)
        ])
      end
    end
  end

  describe "account registration (cross-context invariant, ADR 0016)" do
    setup do
      {:ok, unregistered} =
        Accounts.register_user(:apple, "unregistered-#{System.unique_integer([:positive])}")

      %{unregistered: unregistered}
    end

    test "coach progress can be saved before account registration (not started)", %{
      unregistered: user
    } do
      assert Accounts.get_account_registration(user).status == :not_started
      assert {:ok, %CoachProfile{}} = Coaches.update_profile(user, @required)
    end

    test "completion is blocked while account registration is not started or in progress", %{
      unregistered: user
    } do
      {:ok, _} = Coaches.update_profile(user, @required)

      assert field_codes(Coaches.complete_onboarding(user)) ==
               %{"account_registration" => ["required"]}

      {:ok, _} = Accounts.update_account_registration(user, %{"full_name" => "Marek Kowalski"})
      assert Accounts.get_account_registration(user).status == :in_progress

      assert field_codes(Coaches.complete_onboarding(user)) ==
               %{"account_registration" => ["required"]}

      profile = Coaches.get_profile(user)
      assert profile.onboarding_completed_at == nil
      assert profile.display_name == "Coach Marek"
      # The account is never completed for the user.
      assert Accounts.get_account_registration(user).status == :in_progress

      complete_account_registration!(user)
      assert {:ok, %{onboarding_completed_at: %DateTime{}}} = Coaches.complete_onboarding(user)
    end

    test "missing coach fields and account registration are reported together", %{
      unregistered: user
    } do
      {:ok, _} = Coaches.update_profile(user, %{"city" => "Warsaw"})

      assert field_codes(Coaches.complete_onboarding(user)) == %{
               "account_registration" => ["required"],
               "display_name" => ["required"],
               "country_code" => ["required"],
               "coaching_formats" => ["required"]
             }
    end
  end

  describe "identity separation (ADR 0009, ADR 0020)" do
    test "a coach profile is never derived from the account's full name", %{user: user} do
      assert Accounts.get_account_registration(user).profile.full_name == "Test Person"

      {:ok, profile} = Coaches.update_profile(user, %{"city" => "Warsaw"})
      assert profile.display_name == nil

      assert field_codes(Coaches.complete_onboarding(user)) == %{
               "display_name" => ["required"],
               "country_code" => ["required"],
               "coaching_formats" => ["required"]
             }
    end

    test "updating the account's full name never changes the coach name", %{user: user} do
      complete!(user)
      {:ok, _} = Accounts.update_account_registration(user, %{"full_name" => "Changed Name"})
      assert Coaches.get_profile(user).display_name == "Coach Marek"
    end

    test "a user can be fighter and coach; the profiles never touch each other", %{user: user} do
      complete_fighter_onboarding!(user)
      fighter_before = Fighters.get_profile(user)

      coach = complete!(user)

      {:ok, _} =
        Coaches.update_profile(user, %{"display_name" => "Coach Alex", "city" => "Gdańsk"})

      fighter_after = Fighters.get_profile(user)
      assert fighter_after == fighter_before
      assert fighter_after.display_name == "Alex K."
      assert Coaches.get_profile(user).display_name == "Coach Alex"
      assert Coaches.onboarding_status(coach) == :completed

      {:ok, _} = Fighters.update_profile(user, %{"display_name" => "Alex the Fighter"})
      assert Coaches.get_profile(user).display_name == "Coach Alex"
    end

    test "a coach-only user has no fighter profile, and the reverse", %{user: user} do
      complete!(user)
      assert Fighters.get_profile(user) == nil

      {:ok, fighter_only} =
        Accounts.register_user(:google, "fighter-#{System.unique_integer([:positive])}")

      complete_fighter_onboarding!(fighter_only)
      assert Coaches.get_profile(fighter_only) == nil
      assert Repo.aggregate(FighterProfile, :count) == 1
    end
  end

  describe "ownership" do
    test "each user only ever sees and changes their own profile", %{user: user} do
      {:ok, other} =
        Accounts.register_user(:google, "other-#{System.unique_integer([:positive])}")

      {:ok, mine} = Coaches.update_profile(user, %{"city" => "Warsaw"})
      {:ok, theirs} = Coaches.update_profile(other, %{"city" => "Kraków"})

      assert mine.id != theirs.id
      assert Coaches.get_profile(user).city == "Warsaw"
      assert Coaches.get_profile(other).city == "Kraków"
    end

    test "deleting the user deletes the profile", %{user: user} do
      {:ok, _} = Coaches.update_profile(user, %{"city" => "Warsaw"})
      Repo.delete!(user)
      assert count() == 0
    end
  end

  test "personal data is redacted from inspect output", %{user: user} do
    {:ok, profile} =
      Coaches.update_profile(user, %{
        "display_name" => "Visible Name",
        "brand_name" => "Visible Brand",
        "city" => "Visible City",
        "bio" => "Visible Bio",
        "country_code" => "PL"
      })

    inspected = inspect(profile)

    for value <- ["Visible Name", "Visible Brand", "Visible City", "Visible Bio", "\"PL\""] do
      refute inspected =~ value
    end
  end
end
