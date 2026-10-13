defmodule SimpleFitWeb.CoachProfileControllerTest do
  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Coaches
  alias SimpleFit.Fighters
  alias SimpleFitWeb.ApiSpec

  @path "/api/v1/me/coach-profile"
  @complete_path "/api/v1/me/coach-profile/complete-onboarding"

  @required %{
    "display_name" => "Coach Marek",
    "country_code" => "PL",
    "city" => "Warsaw",
    "coaching_formats" => ["personal_training"]
  }

  @all_requirements ~w(display_name country_code city coaching_formats)

  setup do
    {:ok, user} = Accounts.register_user(:google, "coach-#{System.unique_integer([:positive])}")
    user = complete_account_registration!(user)
    {:ok, credentials} = Accounts.create_session(user)
    %{user: user, token: credentials.access_token}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  defp get_profile(token), do: token |> authed() |> get(@path)

  defp patch_profile(token, body),
    do:
      token
      |> authed()
      |> put_req_header("content-type", "application/json")
      |> patch(@path, body)

  defp complete(token), do: token |> authed() |> post(@complete_path)

  defp profile_body(conn, status) do
    body = json_response(conn, status)
    assert_schema(body, "CoachProfileResponse", ApiSpec.spec())
    body["coach_profile"]
  end

  defp validation_error(conn) do
    body = json_response(conn, 422)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    assert body["error"]["code"] == "validation_error"
    body["error"]["details"]["field_codes"]
  end

  defp new_session(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  describe "GET /api/v1/me/coach-profile" do
    test "before onboarding: not_started, empty fields, every requirement missing, nothing created",
         %{user: user, token: token} do
      profile = token |> get_profile() |> profile_body(200)

      assert profile == %{
               "onboarding" => %{
                 "status" => "not_started",
                 "completed_at" => nil,
                 "missing_requirements" => @all_requirements
               },
               "display_name" => nil,
               "brand_name" => nil,
               "country_code" => nil,
               "city" => nil,
               "bio" => nil,
               "languages" => [],
               "coaching_formats" => [],
               "competition_levels" => []
             }

      assert Coaches.get_profile(user) == nil
    end

    test "is never cached", %{token: token} do
      conn = get_profile(token)
      assert get_resp_header(conn, "cache-control") |> Enum.any?(&(&1 =~ "no-store"))
    end

    test "with a completed profile: completed with its completion time", %{token: token} do
      token |> patch_profile(@required) |> profile_body(200)
      completed = token |> complete() |> profile_body(200)

      profile = token |> get_profile() |> profile_body(200)
      assert profile["onboarding"] == completed["onboarding"]
      assert profile["onboarding"]["status"] == "completed"
      assert {:ok, _, _} = DateTime.from_iso8601(profile["onboarding"]["completed_at"])
    end

    test "exposes no ids, user id or internal timestamps", %{user: user, token: token} do
      token |> patch_profile(@required) |> profile_body(200)
      conn = get_profile(token)

      refute conn.resp_body =~ user.id

      for field <- ~w(id user_id inserted_at updated_at onboarding_completed_at full_name) do
        refute conn.resp_body =~ ~s("#{field}")
      end
    end

    test "requires authentication", %{conn: conn} do
      assert json_response(get(conn, @path), 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "PATCH /api/v1/me/coach-profile" do
    test "the first save creates an in-progress profile that a second client resumes", %{
      user: user,
      token: token
    } do
      profile =
        token
        |> patch_profile(%{"display_name" => "Coach Marek", "languages" => ["pl", "en"]})
        |> profile_body(200)

      assert profile["onboarding"]["status"] == "in_progress"

      assert profile["onboarding"]["missing_requirements"] ==
               ~w(country_code city coaching_formats)

      # Another device of the same user continues from the stored state.
      other_device = new_session(user)
      resumed = other_device |> get_profile() |> profile_body(200)
      assert resumed["display_name"] == "Coach Marek"
      assert resumed["languages"] == ["pl", "en"]

      updated = other_device |> patch_profile(%{"city" => "Warsaw"}) |> profile_body(200)
      assert updated["display_name"] == "Coach Marek"
      assert updated["city"] == "Warsaw"
    end

    test "an empty PATCH keeps not_started and creates no profile", %{user: user, token: token} do
      for body <- [%{}, %{"languages" => []}, %{"bio" => nil}, %{"brand_name" => ""}] do
        profile = token |> patch_profile(body) |> profile_body(200)
        assert profile["onboarding"]["status"] == "not_started"
        assert profile["onboarding"]["missing_requirements"] == @all_requirements
      end

      assert Coaches.get_profile(user) == nil
    end

    test "omitted fields are unchanged; null, blank and [] clear optional fields", %{token: token} do
      token
      |> patch_profile(%{
        "brand_name" => "Marek Boxing",
        "bio" => "Footwork first.",
        "languages" => ["pl"],
        "competition_levels" => ["amateur"],
        "city" => "Warsaw"
      })
      |> profile_body(200)

      profile =
        token
        |> patch_profile(%{
          "brand_name" => nil,
          "bio" => " ",
          "languages" => nil,
          "competition_levels" => []
        })
        |> profile_body(200)

      assert %{
               "brand_name" => nil,
               "bio" => nil,
               "languages" => [],
               "competition_levels" => [],
               "city" => "Warsaw"
             } = profile
    end

    test "a valid save of every required field is not completion", %{token: token} do
      profile = token |> patch_profile(@required) |> profile_body(200)

      assert profile["onboarding"] == %{
               "status" => "in_progress",
               "completed_at" => nil,
               "missing_requirements" => []
             }
    end

    test "validation failures use the envelope with field codes and change nothing", %{
      user: user,
      token: token
    } do
      codes =
        token
        |> patch_profile(%{
          "city" => "Warsaw",
          "display_name" => String.duplicate("x", 61),
          "country_code" => "ZZ",
          "languages" => ["de"],
          "coaching_formats" => ["strength_conditioning"],
          "competition_levels" => ["fitness"]
        })
        |> validation_error()

      assert codes == %{
               "display_name" => ["too_long"],
               "country_code" => ["invalid_choice"],
               "languages" => ["invalid_choice"],
               "coaching_formats" => ["invalid_choice"],
               "competition_levels" => ["invalid_choice"]
             }

      assert Coaches.get_profile(user) == nil
    end

    test "repeated values are rejected, never silently dropped", %{token: token} do
      assert token
             |> patch_profile(%{"coaching_formats" => ["fight_camps", "fight_camps"]})
             |> validation_error() ==
               %{"coaching_formats" => ["invalid"]}
    end

    test "wrong JSON types are invalid_type", %{token: token} do
      assert token |> patch_profile(%{"languages" => "pl", "city" => 7}) |> validation_error() ==
               %{"languages" => ["invalid_type"], "city" => ["invalid_type"]}
    end

    test "unknown fields and ownership claims are ignored, never written", %{
      user: user,
      token: token
    } do
      {:ok, other} = Accounts.register_user(:email, "other-coach@example.com")

      profile =
        token
        |> patch_profile(%{
          "city" => "Warsaw",
          "user_id" => other.id,
          "coach_id" => Ecto.UUID.generate(),
          "id" => Ecto.UUID.generate(),
          "onboarding_completed_at" => "2026-10-13T10:00:00Z",
          "onboarding" => %{"status" => "completed"},
          "capabilities" => ["COACH"],
          "gym_id" => Ecto.UUID.generate()
        })
        |> profile_body(200)

      assert profile["onboarding"]["status"] == "in_progress"
      assert Coaches.get_profile(user).city == "Warsaw"
      assert Coaches.get_profile(other) == nil
    end

    test "requires authentication", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> patch(@path, %{"city" => "Warsaw"})

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "POST /api/v1/me/coach-profile/complete-onboarding" do
    test "fails before onboarding has started, lists every requirement and creates nothing", %{
      user: user,
      token: token
    } do
      assert token |> complete() |> validation_error() ==
               Map.new(@all_requirements, &{&1, ["required"]})

      assert Coaches.get_profile(user) == nil
    end

    test "fails with a required code per missing requirement while incomplete", %{token: token} do
      token
      |> patch_profile(Map.drop(@required, ["city", "coaching_formats"]))
      |> profile_body(200)

      assert token |> complete() |> validation_error() ==
               %{"city" => ["required"], "coaching_formats" => ["required"]}

      assert (token |> get_profile() |> profile_body(200))["onboarding"]["status"] ==
               "in_progress"
    end

    test "completes when every requirement is present and is idempotent", %{token: token} do
      token |> patch_profile(@required) |> profile_body(200)

      first = token |> complete() |> profile_body(200)
      assert first["onboarding"]["status"] == "completed"
      assert first["onboarding"]["missing_requirements"] == []

      again = token |> complete() |> profile_body(200)
      assert again["onboarding"]["completed_at"] == first["onboarding"]["completed_at"]
    end

    test "a completed profile stays editable but cannot clear a requirement", %{token: token} do
      token |> patch_profile(@required) |> profile_body(200)
      completed = token |> complete() |> profile_body(200)

      updated =
        token |> patch_profile(%{"bio" => "Fight camps for amateurs."}) |> profile_body(200)

      assert updated["onboarding"] == completed["onboarding"]

      assert token |> patch_profile(%{"coaching_formats" => []}) |> validation_error() ==
               %{"coaching_formats" => ["required"]}

      assert token |> patch_profile(%{"display_name" => nil}) |> validation_error() ==
               %{"display_name" => ["required"]}
    end

    test "is blocked while shared account registration is incomplete and keeps the progress" do
      {:ok, user} =
        Accounts.register_user(:apple, "unregistered-#{System.unique_integer([:positive])}")

      token = new_session(user)

      token |> patch_profile(@required) |> profile_body(200)

      assert token |> complete() |> validation_error() == %{
               "account_registration" => ["required"]
             }

      profile = token |> get_profile() |> profile_body(200)
      assert profile["onboarding"]["status"] == "in_progress"
      assert profile["display_name"] == "Coach Marek"
    end

    test "requires authentication", %{conn: conn} do
      assert json_response(post(conn, @complete_path), 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "sessions and isolation" do
    test "a revoked session can no longer read or write the profile", %{token: token} do
      token |> patch_profile(%{"city" => "Warsaw"}) |> profile_body(200)
      :ok = Accounts.revoke_session({:access, token})

      assert json_response(get_profile(token), 401)["error"]["code"] == "unauthorized"

      assert json_response(patch_profile(token, %{"city" => "Kraków"}), 401)["error"]["code"] ==
               "unauthorized"

      assert json_response(complete(token), 401)["error"]["code"] == "unauthorized"
    end

    test "two users only ever see their own profiles", %{token: token} do
      {:ok, other} =
        Accounts.register_user(:google, "coach-b-#{System.unique_integer([:positive])}")

      other_token = new_session(complete_account_registration!(other))

      token |> patch_profile(%{"city" => "Warsaw"}) |> profile_body(200)
      other_token |> patch_profile(%{"city" => "Kraków"}) |> profile_body(200)

      assert (token |> get_profile() |> profile_body(200))["city"] == "Warsaw"
      assert (other_token |> get_profile() |> profile_body(200))["city"] == "Kraków"
    end

    test "a fighter becomes a coach without touching the fighter profile or gaining access", %{
      user: user,
      token: token
    } do
      complete_fighter_onboarding!(user)
      fighter = Fighters.get_profile(user)

      token |> patch_profile(@required) |> profile_body(200)
      token |> complete() |> profile_body(200)

      assert Fighters.get_profile(user) == fighter
      # Coach capability is not projected by entry until the Coach entry ticket.
      entry = token |> authed() |> get("/api/v1/me/entry") |> json_response(200)
      assert entry["entry"]["capabilities"] == ["FIGHTER"]
    end
  end
end
