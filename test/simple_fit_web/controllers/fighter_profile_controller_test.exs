defmodule SimpleFitWeb.FighterProfileControllerTest do
  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias SimpleFit.Accounts
  alias SimpleFit.Fighters
  alias SimpleFitWeb.ApiSpec

  @path "/api/v1/me/fighter-profile"
  @complete_path "/api/v1/me/fighter-profile/complete-onboarding"

  @required %{
    "display_name" => "Alex K.",
    "username" => "fighter_one",
    "country_code" => "PL",
    "city" => "Warsaw",
    "experience_level" => "competitive_amateur",
    "stance" => "orthodox"
  }

  @all_requirements ~w(display_name username country_code city experience_level stance)

  setup do
    {:ok, user} = Accounts.register_user(:google, "fighter-#{System.unique_integer([:positive])}")
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
    assert_schema(body, "FighterProfileResponse", ApiSpec.spec())
    body["fighter_profile"]
  end

  defp validation_error(conn) do
    body = json_response(conn, 422)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    assert body["error"]["code"] == "validation_error"
    body["error"]["details"]["field_codes"]
  end

  describe "GET /api/v1/me/fighter-profile" do
    test "before onboarding: not_started, empty fields, every requirement missing", %{
      user: user,
      token: token
    } do
      profile = token |> get_profile() |> profile_body(200)

      assert profile["onboarding"] == %{
               "status" => "not_started",
               "completed_at" => nil,
               "missing_requirements" => @all_requirements
             }

      assert profile["goals"] == []
      assert profile["display_name"] == nil and profile["weight_class"] == nil
      # Reading never creates a profile.
      assert Fighters.get_profile(user) == nil
    end

    test "with partial onboarding: in_progress, saved fields, remaining requirements", %{
      user: user,
      token: token
    } do
      {:ok, _} =
        Fighters.update_profile(user, %{
          "display_name" => "Alex K.",
          "experience_level" => "competitive_amateur",
          "amateur_bout_count" => 14,
          "current_weight_kg" => 73.8,
          "goals" => ["competition"]
        })

      profile = token |> get_profile() |> profile_body(200)

      assert profile["onboarding"]["status"] == "in_progress"

      assert profile["onboarding"]["missing_requirements"] ==
               ~w(username country_code city stance)

      assert profile["display_name"] == "Alex K."
      assert profile["amateur_bout_count"] == 14
      assert profile["current_weight_kg"] == 73.8
      assert profile["goals"] == ["competition"]
    end

    test "with completed onboarding: completed with its completion time", %{
      user: user,
      token: token
    } do
      {:ok, _} = Fighters.update_profile(user, @required)
      {:ok, completed} = Fighters.complete_onboarding(user)

      profile = token |> get_profile() |> profile_body(200)

      assert profile["onboarding"] == %{
               "status" => "completed",
               "completed_at" => DateTime.to_iso8601(completed.onboarding_completed_at),
               "missing_requirements" => []
             }
    end

    test "exposes no ids, user id or internal timestamps", %{user: user, token: token} do
      {:ok, profile} = Fighters.update_profile(user, @required)
      conn = get_profile(token)

      for value <- [profile.id, user.id], do: refute(conn.resp_body =~ value)

      for field <- ~w(id user_id inserted_at updated_at onboarding_completed_at) do
        refute conn.resp_body =~ ~s("#{field}")
      end
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, @path)

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      assert_schema(json_response(conn, 401), "ErrorResponse", ApiSpec.spec())
    end
  end

  describe "PATCH /api/v1/me/fighter-profile" do
    test "saves partial progress and returns the new state", %{user: user, token: token} do
      profile =
        token
        |> patch_profile(%{"display_name" => "Alex K.", "stance" => "southpaw"})
        |> profile_body(200)

      assert profile["onboarding"]["status"] == "in_progress"
      assert profile["display_name"] == "Alex K."
      assert profile["stance"] == "southpaw"
      assert Fighters.get_profile(user).stance == :southpaw
    end

    test "an empty PATCH keeps not_started and creates no profile", %{user: user, token: token} do
      for body <- [%{}, %{"goals" => []}, %{"city" => nil}] do
        profile = token |> patch_profile(body) |> profile_body(200)

        assert profile["onboarding"]["status"] == "not_started"
        assert profile["onboarding"]["missing_requirements"] == @all_requirements
      end

      assert Fighters.get_profile(user) == nil
    end

    test "weight with more than one decimal place is invalid_format", %{token: token} do
      assert token |> patch_profile(%{"current_weight_kg" => 81.27}) |> validation_error() ==
               %{"current_weight_kg" => ["invalid_format"]}

      profile = token |> patch_profile(%{"current_weight_kg" => 81.2}) |> profile_body(200)
      assert profile["current_weight_kg"] == 81.2
    end

    test "an unassigned country code is invalid_choice", %{token: token} do
      assert token |> patch_profile(%{"country_code" => "ZZ"}) |> validation_error() ==
               %{"country_code" => ["invalid_choice"]}
    end

    test "incremental saves keep earlier steps", %{token: token} do
      token |> patch_profile(%{"display_name" => "Alex K."}) |> profile_body(200)

      profile =
        token
        |> patch_profile(%{
          "goals" => ["improve_technique", "competition"],
          "weight_class" => "minus_75"
        })
        |> profile_body(200)

      assert profile["display_name"] == "Alex K."
      assert profile["goals"] == ["improve_technique", "competition"]
      assert profile["weight_class"] == "minus_75"
    end

    test "validation failures use the envelope with field codes and change nothing", %{
      user: user,
      token: token
    } do
      codes =
        token
        |> patch_profile(%{"stance" => "wrong-footed", "height_cm" => 0, "city" => "Warsaw"})
        |> validation_error()

      assert codes == %{"stance" => ["invalid_choice"], "height_cm" => ["out_of_range"]}
      assert Fighters.get_profile(user) == nil
    end

    test "a taken username is already_exists", %{token: token} do
      {:ok, other} = Accounts.register_user(:email, "other@example.com")
      {:ok, _} = Fighters.update_profile(other, %{"username" => "fighter_one"})

      assert token |> patch_profile(%{"username" => "FIGHTER_ONE"}) |> validation_error() ==
               %{"username" => ["already_exists"]}
    end

    test "cannot set the completion marker or another user's profile", %{user: user, token: token} do
      {:ok, other} = Accounts.register_user(:email, "other@example.com")

      profile =
        token
        |> patch_profile(%{
          "onboarding_completed_at" => "2026-10-08T10:00:00Z",
          "user_id" => other.id,
          "city" => "Warsaw"
        })
        |> profile_body(200)

      assert profile["onboarding"]["status"] == "in_progress"
      assert Fighters.get_profile(user).city == "Warsaw"
      assert Fighters.get_profile(other) == nil
    end

    test "requires authentication", %{conn: conn} do
      conn = conn |> put_req_header("content-type", "application/json") |> patch(@path, %{})
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "POST /api/v1/me/fighter-profile/complete-onboarding" do
    test "completes when every requirement is present", %{token: token} do
      token |> patch_profile(@required) |> profile_body(200)

      profile = token |> complete() |> profile_body(200)

      assert profile["onboarding"]["status"] == "completed"
      assert is_binary(profile["onboarding"]["completed_at"])
      assert profile["onboarding"]["missing_requirements"] == []

      assert (token |> get_profile() |> profile_body(200))["onboarding"]["status"] == "completed"
    end

    test "fails with a required code per missing requirement while incomplete", %{token: token} do
      token
      |> patch_profile(Map.drop(@required, ["city", "stance"]))
      |> profile_body(200)

      assert token |> complete() |> validation_error() ==
               %{"city" => ["required"], "stance" => ["required"]}

      assert (token |> get_profile() |> profile_body(200))["onboarding"]["status"] ==
               "in_progress"
    end

    test "fails before onboarding has started and creates nothing", %{user: user, token: token} do
      assert token |> complete() |> validation_error() ==
               Map.new(@all_requirements, &{&1, ["required"]})

      assert Fighters.get_profile(user) == nil
    end

    test "is idempotent once completed", %{token: token} do
      token |> patch_profile(@required) |> profile_body(200)
      first = token |> complete() |> profile_body(200)
      again = token |> complete() |> profile_body(200)

      assert again["onboarding"]["completed_at"] == first["onboarding"]["completed_at"]
    end

    test "requires authentication", %{conn: conn} do
      assert json_response(post(conn, @complete_path), 401)["error"]["code"] == "unauthorized"
    end
  end

  test "the routes are the versioned product resources (ADR 0003)" do
    paths = Map.keys(ApiSpec.spec().paths)

    assert @path in paths and @complete_path in paths
    refute "/api/me/fighter-profile" in paths
    assert @path =~ ~r{^/api/v1/}
  end
end
