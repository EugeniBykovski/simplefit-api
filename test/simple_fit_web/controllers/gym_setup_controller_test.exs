defmodule SimpleFitWeb.GymSetupControllerTest do
  @moduledoc """
  Gym setup over HTTP (SF-85): `getGymSetup`, `updateGymSetup`,
  `setGymPrimaryLocation`, `completeGymSetup` and `discardGymDraft`.
  OpenAPI schemas, `no-store`, and 200 / 204 / 401 / 403 / 404 / 409 / 422.
  """

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers

  alias SimpleFit.Accounts
  alias SimpleFitWeb.ApiSpec

  @address %{country_code: "PL", city: "Warsaw", address_line: "ul. Ząbkowska 31"}

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp setup_body(conn, status \\ 200) do
    body = json_response(conn, status)
    assert_schema(body, "GymSetupResponse", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body["setup"]
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  defp gym_path(gym_id, suffix \\ ""), do: "/api/v1/gyms/#{gym_id}#{suffix}"

  test "the draft lifecycle end to end: read, save, locate, complete" do
    owner = registered!()
    gym = draft_gym!(owner)
    t = token(owner)

    setup = t |> authed() |> get(gym_path(gym.id, "/setup")) |> setup_body()
    assert setup["missing_requirements"] == ["primary_location"]

    t
    |> authed()
    |> post(gym_path(gym.id, "/complete-setup"))
    |> error(422, "validation_error")
    |> then(&assert(&1["details"]["field_codes"] == %{"primary_location" => ["required"]}))

    saved =
      t
      |> authed()
      |> patch(
        gym_path(gym.id, "/setup"),
        Jason.encode!(%{
          tagline: "Boxing for everyone.",
          accent_color: "#E07A5F",
          expected_revision: 1
        })
      )
      |> setup_body()

    assert {saved["tagline"], saved["accent_color"], saved["revision"]} ==
             {"Boxing for everyone.", "#e07a5f", 2}

    located =
      t
      |> authed()
      |> put(
        gym_path(gym.id, "/setup/primary-location"),
        Jason.encode!(Map.put(@address, :expected_revision, 2))
      )
      |> setup_body()

    assert located["primary_location"]["city"] == "Warsaw" and
             located["missing_requirements"] == []

    done = t |> authed() |> post(gym_path(gym.id, "/complete-setup")) |> setup_body()
    assert done["setup_status"] == "completed"

    again = t |> authed() |> post(gym_path(gym.id, "/complete-setup")) |> setup_body()
    assert again["revision"] == done["revision"]

    entry = t |> authed() |> get("/api/v1/me/entry?intent=gym") |> json_response(200)
    assert entry["entry"]["destination"] == "gym_home"
  end

  test "validation, stale revisions and read-only fields" do
    owner = registered!()
    gym = draft_gym!(owner)
    t = token(owner)

    error =
      t
      |> authed()
      |> patch(
        gym_path(gym.id, "/setup"),
        Jason.encode!(%{website: "javascript:x", expected_revision: 1})
      )
      |> error(422, "validation_error")

    assert Map.has_key?(error["details"]["fields"], "website")

    t
    |> authed()
    |> patch(gym_path(gym.id, "/setup"), Jason.encode!(%{setup_status: "completed"}))
    |> error(422, "validation_error")

    t
    |> authed()
    |> put(gym_path(gym.id, "/setup/primary-location"), Jason.encode!(%{city: "Warsaw"}))
    |> error(422, "validation_error")

    conflict =
      t
      |> authed()
      |> patch(gym_path(gym.id, "/setup"), Jason.encode!(%{tagline: "x", expected_revision: 9}))
      |> error(409, "conflict")

    assert conflict["details"] == %{"revision" => "stale"}
  end

  test "conditional writes: a missing revision is 422, a stale one 409; discarded keys stay spent" do
    owner = registered!()
    gym = draft_gym!(owner)
    t = token(owner)

    missing =
      t
      |> authed()
      |> patch(gym_path(gym.id, "/setup"), Jason.encode!(%{tagline: "x"}))
      |> error(422, "validation_error")

    assert missing["details"]["field_codes"]["expected_revision"] == ["required"]

    t
    |> authed()
    |> put(gym_path(gym.id, "/setup/primary-location"), Jason.encode!(@address))
    |> error(422, "validation_error")

    noop =
      t
      |> authed()
      |> patch(gym_path(gym.id, "/setup"), Jason.encode!(%{expected_revision: 1}))
      |> setup_body()

    assert noop["revision"] == 1

    key = Ecto.UUID.generate()
    body = Jason.encode!(%{client_request_id: key, name: "Spent", gym_type: "boxing_gym"})
    other = registered!()
    ot = token(other)
    %{"gym" => %{"id" => id}} = ot |> authed() |> post("/api/v1/gyms", body) |> json_response(201)
    204 = (ot |> authed() |> delete(gym_path(id))).status

    conflict = ot |> authed() |> post("/api/v1/gyms", body) |> error(409, "conflict")
    assert conflict["details"] == %{"client_request_id" => "discarded"}
  end

  test "role-limited staff get 403, outsiders 404, no session 401" do
    owner = registered!()
    gym = completed_gym!(owner)
    coach = registered!()
    staff!(gym.id, coach, :coach)
    manager = registered!()
    staff!(gym.id, manager, :manager)

    coach_token = token(coach)
    coach_token |> authed() |> get(gym_path(gym.id, "/setup")) |> setup_body()

    coach_token
    |> authed()
    |> patch(gym_path(gym.id, "/setup"), Jason.encode!(%{tagline: "x"}))
    |> error(403, "forbidden")

    coach_token
    |> authed()
    |> put(gym_path(gym.id, "/setup/primary-location"), Jason.encode!(@address))
    |> error(403, "forbidden")

    manager_token = token(manager)

    manager_token
    |> authed()
    |> patch(gym_path(gym.id, "/setup"), Jason.encode!(%{tagline: "ok", expected_revision: 1}))
    |> setup_body()

    manager_token
    |> authed()
    |> post(gym_path(gym.id, "/complete-setup"))
    |> error(403, "forbidden")

    manager_token |> authed() |> delete(gym_path(gym.id)) |> error(403, "forbidden")

    outsider = token(registered!())

    for {method, suffix, body} <- [
          {:get, "/setup", nil},
          {:patch, "/setup", %{tagline: "x"}},
          {:put, "/setup/primary-location", @address},
          {:post, "/complete-setup", nil},
          {:delete, "", nil}
        ],
        id <- [gym.id, Ecto.UUID.generate()] do
      outsider
      |> authed()
      |> dispatch(@endpoint, method, gym_path(id, suffix), body && Jason.encode!(body))
      |> error(404, "not_found")
    end

    build_conn() |> get(gym_path(gym.id, "/setup")) |> error(401, "unauthorized")
  end

  test "discard: 204 for the owner's draft, then 404; 409 for a completed gym" do
    owner = registered!()
    draft = draft_gym!(owner)
    t = token(owner)

    conn = t |> authed() |> delete(gym_path(draft.id))
    assert response(conn, 204) == ""
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    t |> authed() |> delete(gym_path(draft.id)) |> error(404, "not_found")
    t |> authed() |> get(gym_path(draft.id, "/setup")) |> error(404, "not_found")

    completed_owner = registered!()
    completed = completed_gym!(completed_owner)
    owner_token = token(completed_owner)

    conflict = owner_token |> authed() |> delete(gym_path(completed.id)) |> error(409, "conflict")
    assert conflict["details"] == %{"setup_status" => "completed"}
  end
end
