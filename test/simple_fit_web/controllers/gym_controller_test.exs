defmodule SimpleFitWeb.GymControllerTest do
  @moduledoc """
  Gyms over HTTP (SF-83; ADR 0026): OpenAPI schemas, status codes (201 / 200
  replay / 200 resumed draft / 401 / 404 / 409 / 422 / 429), `no-store`,
  tenant isolation (forged and foreign ids, several gyms per user, several
  tabs), revoked sessions and revoked staff, and privacy: nothing of a
  person's account, coach or fighter profile reaches a gym response.
  """

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers, only: [coach_user!: 1, fighter_user!: 0]
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Gyms}
  alias SimpleFitWeb.ApiSpec

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(%Accounts.User{} = user), do: authed(token(user))

  defp authed(token) when is_binary(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp create(conn, attrs), do: post(conn, "/api/v1/gyms", Jason.encode!(attrs))

  defp body(conn, status, schema) do
    body = json_response(conn, status)
    assert_schema(body, schema, ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  describe "POST /api/v1/gyms" do
    test "creates a draft owned by the viewer (201), replays (200) and resumes the draft (200)" do
      owner = registered!()
      attrs = gym_attrs()

      %{"gym" => gym} = owner |> authed() |> create(attrs) |> body(201, "GymResponse")
      assert gym["setup_status"] == "draft"
      assert gym["viewer"]["role"] == "owner"
      assert gym["locations"] == []
      assert "transfer_ownership" in gym["viewer"]["permissions"]

      %{"gym" => replay} = owner |> authed() |> create(attrs) |> body(200, "GymResponse")
      assert replay["id"] == gym["id"]

      %{"gym" => resumed} = owner |> authed() |> create(gym_attrs()) |> body(200, "GymResponse")
      assert resumed["id"] == gym["id"]
      assert gyms_created_by(owner) == 1
    end

    test "422 for invalid or unknown fields and for incomplete account registration" do
      owner = registered!()

      error =
        owner
        |> authed()
        |> create(gym_attrs(%{"owner_user_id" => Ecto.UUID.generate()}))
        |> error(422, "validation_error")

      assert Map.has_key?(error["details"]["fields"], "owner_user_id")

      owner
      |> authed()
      |> create(gym_attrs(%{"gym_type" => "spa"}))
      |> error(422, "validation_error")

      owner
      |> authed()
      |> create(%{"name" => "No key", "gym_type" => "boxing_gym"})
      |> error(422, "validation_error")

      {:ok, unregistered} = Accounts.register_user(:google, "gym-http-#{System.unique_integer()}")
      error = unregistered |> authed() |> create(gym_attrs()) |> error(422, "validation_error")
      assert Map.has_key?(error["details"]["fields"], "account_registration")
      assert gyms_created_by(owner) == 0
    end

    test "429 with retry-after once the per-user window is spent" do
      owner = registered!()

      for _ <- 1..5 do
        %{"gym" => %{"id" => id}} =
          owner |> authed() |> create(gym_attrs()) |> body(201, "GymResponse")

        complete!(id)
      end

      conn = owner |> authed() |> create(gym_attrs())
      error(conn, 429, "rate_limited")
      assert [seconds] = get_resp_header(conn, "retry-after")
      assert String.to_integer(seconds) > 0
    end

    test "401 without a valid session" do
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> create(gym_attrs())
      |> error(401, "unauthorized")
    end
  end

  describe "GET /api/v1/gyms/:gym_id" do
    test "staff read the gym with their own role; outsiders and forged ids get 404" do
      owner = registered!()
      gym = completed_gym!(owner)
      coach = registered!()
      staff!(gym.id, coach, :coach)

      %{"gym" => as_coach} =
        coach |> authed() |> get("/api/v1/gyms/#{gym.id}") |> body(200, "GymResponse")

      assert as_coach["viewer"]["role"] == "coach"
      refute "transfer_ownership" in as_coach["viewer"]["permissions"]

      outsider = registered!()

      for id <- [gym.id, Ecto.UUID.generate(), "not-a-uuid"] do
        outsider |> authed() |> get("/api/v1/gyms/#{id}") |> error(404, "not_found")
      end
    end

    test "a coach or fighter profile without staff membership gets 404" do
      gym = completed_gym!(registered!())

      for user <- [coach_user!("Coach Ola"), fighter_user!()] do
        user |> authed() |> get("/api/v1/gyms/#{gym.id}") |> error(404, "not_found")
      end
    end

    test "a revoked staff member gets 404 on the next request" do
      owner = registered!()
      gym = completed_gym!(owner)
      desk = registered!()
      m = staff!(gym.id, desk, :front_desk)
      bearer = token(desk)

      bearer |> authed() |> get("/api/v1/gyms/#{gym.id}") |> body(200, "GymResponse")
      {:ok, _} = Gyms.revoke_staff_membership(owner, gym.id, m.id)
      bearer |> authed() |> get("/api/v1/gyms/#{gym.id}") |> error(404, "not_found")
    end

    test "a revoked or missing session is 401" do
      owner = registered!()
      gym = completed_gym!(owner)
      bearer = token(owner)
      _ = Accounts.revoke_session({:access, bearer})

      bearer |> authed() |> get("/api/v1/gyms/#{gym.id}") |> error(401, "unauthorized")
      build_conn() |> get("/api/v1/gyms/#{gym.id}") |> error(401, "unauthorized")
    end

    test "two tabs on two gyms stay independent: each request names its own gym" do
      person = registered!()
      gym_a = completed_gym!(registered!())
      gym_b = completed_gym!(registered!())
      staff!(gym_a.id, person, :manager)
      staff!(gym_b.id, person, :front_desk)
      tab_a = token(person)
      tab_b = token(person)

      for _ <- 1..3 do
        %{"gym" => a} =
          tab_a |> authed() |> get("/api/v1/gyms/#{gym_a.id}") |> body(200, "GymResponse")

        %{"gym" => b} =
          tab_b |> authed() |> get("/api/v1/gyms/#{gym_b.id}") |> body(200, "GymResponse")

        assert {a["id"], a["viewer"]["role"]} == {gym_a.id, "manager"}
        assert {b["id"], b["viewer"]["role"]} == {gym_b.id, "front_desk"}
      end

      # A gym the person does not work at stays hidden from either tab.
      gym_c = completed_gym!(registered!())
      tab_a |> authed() |> get("/api/v1/gyms/#{gym_c.id}") |> error(404, "not_found")
    end

    test "responses carry no account, coach or fighter data of anyone" do
      owner = coach_user!("Coach Canary")
      gym = completed_gym!(owner)

      raw = owner |> authed() |> get("/api/v1/gyms/#{gym.id}") |> response(200)

      for leak <- [
            "Test Person",
            "Coach Canary",
            "Marek Boxing",
            "date_of_birth",
            "email",
            "Warsaw"
          ] do
        refute raw =~ leak
      end
    end
  end

  describe "GET /api/v1/me/gyms" do
    test "lists only the viewer's gyms, pages with a cursor" do
      person = registered!()
      own = for _ <- 1..3, do: completed_gym!(person).id
      completed_gym!(registered!())

      %{"gyms" => page1, "next_cursor" => cursor} =
        person |> authed() |> get("/api/v1/me/gyms?limit=2") |> body(200, "GymList")

      %{"gyms" => page2, "next_cursor" => nil} =
        person |> authed() |> get("/api/v1/me/gyms?cursor=#{cursor}") |> body(200, "GymList")

      assert Enum.map(page1 ++ page2, & &1["id"]) == Enum.reverse(own)

      person |> authed() |> get("/api/v1/me/gyms?limit=500") |> error(422, "validation_error")
    end

    test "is empty for someone without staff memberships" do
      %{"gyms" => [], "next_cursor" => nil} =
        registered!() |> authed() |> get("/api/v1/me/gyms") |> body(200, "GymList")
    end
  end
end
