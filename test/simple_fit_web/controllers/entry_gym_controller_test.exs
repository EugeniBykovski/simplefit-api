defmodule SimpleFitWeb.EntryGymControllerTest do
  @moduledoc """
  Gym entry over HTTP (SF-84): `resolveMyEntry` with a Gym intent and gym
  context, and `chooseMyEntryContext` for gyms. OpenAPI schemas, `no-store`,
  401 / 404 / 409 / 422, no existence disclosure for foreign gym ids, and
  the session lifecycle: refresh, two devices, two tabs and logout racing a
  choice.
  """

  use SimpleFitWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import SimpleFit.FighterOnboardingHelpers
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFitWeb.ApiSpec

  @entry "/api/v1/me/entry"
  @choice "/api/v1/me/entry/context"

  defp session!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials
  end

  defp authed(token),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

  defp entry(token, query \\ ""), do: token |> authed() |> get(@entry <> query)
  defp choose(token, body), do: token |> authed() |> put(@choice, Jason.encode!(body))

  defp entry!(token, query \\ "") do
    conn = entry(token, query)
    body = json_response(conn, 200)
    assert_schema(body, "EntryResponse", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body["entry"]
  end

  defp error(conn, status, code) do
    assert %{"error" => %{"code" => ^code} = error} = json_response(conn, status)
    assert_schema(json_response(conn, status), "ErrorResponse", ApiSpec.spec())
    error
  end

  describe "GET /api/v1/me/entry with gyms" do
    test "Gym intent: setup start, draft resume and gym entry, schema-valid" do
      user = registered!()
      token = session!(user).access_token

      assert %{
               "destination" => "gym_onboarding",
               "reason" => "gym_setup_not_started",
               "gym_id" => nil
             } =
               entry!(token, "?intent=gym")

      draft = draft_gym!(user)

      assert %{"destination" => "gym_onboarding", "gym_id" => id, "gym_workspaces" => [ws]} =
               entry!(token, "?intent=gym")

      assert id == draft.id
      assert ws["setup_status"] == "draft" and ws["available_actions"] == ["continue_setup"]

      complete!(draft.id)

      assert %{"destination" => "gym_home", "capabilities" => ["GYM_WORKSPACE"]} =
               entry!(token, "?intent=gym")
    end

    test "a foreign or unknown gym id answers exactly like no gym context" do
      user = registered!()
      complete_fighter_onboarding!(user)
      token = session!(user).access_token
      foreign = completed_gym!(registered!())

      plain = entry!(token)
      foreign_answer = entry!(token, "?context=gym&gym_id=#{foreign.id}")
      unknown_answer = entry!(token, "?context=gym&gym_id=#{Ecto.UUID.generate()}")

      assert foreign_answer == plain
      assert unknown_answer == plain
      refute inspect(foreign_answer) =~ foreign.id
    end

    test "malformed or misplaced gym ids are validation errors" do
      token = session!(registered!()).access_token
      entry(token, "?context=gym") |> error(422, "validation_error")
      entry(token, "?context=gym&gym_id=nope") |> error(422, "validation_error")
      entry(token, "?gym_id=#{Ecto.UUID.generate()}") |> error(422, "validation_error")
    end
  end

  describe "PUT /api/v1/me/entry/context with a gym" do
    setup do
      user = registered!()
      complete_fighter_onboarding!(user)
      gym = completed_gym!(user)
      %{user: user, gym: gym, credentials: session!(user)}
    end

    test "a completed gym of the viewer is recorded (204) and becomes the default", ctx do
      conn = choose(ctx.credentials.access_token, %{context: "gym", gym_id: ctx.gym.id})
      assert response(conn, 204) == ""
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert %{"destination" => "gym_home", "reason" => "last_context", "gym_id" => id} =
               entry!(ctx.credentials.access_token)

      assert id == ctx.gym.id
    end

    test "foreign and unknown gyms are 404, drafts 409, malformed bodies 422; nothing recorded",
         ctx do
      token = ctx.credentials.access_token
      foreign = completed_gym!(registered!())
      draft_owner = registered!()
      draft = draft_gym!(draft_owner)

      for gym_id <- [foreign.id, Ecto.UUID.generate(), draft.id] do
        choose(token, %{context: "gym", gym_id: gym_id}) |> error(404, "not_found")
      end

      own_draft_token = session!(draft_owner).access_token

      conflict =
        choose(own_draft_token, %{context: "gym", gym_id: draft.id}) |> error(409, "conflict")

      assert conflict["details"] == %{"setup_status" => "draft"}

      choose(token, %{context: "gym"}) |> error(422, "validation_error")
      choose(token, %{context: "gym", gym_id: "x"}) |> error(422, "validation_error")
      choose(token, %{context: "fighter", gym_id: ctx.gym.id}) |> error(422, "validation_error")

      assert Repo.get(ContextChoice, ctx.user.id) == nil
      assert Repo.get(ContextChoice, draft_owner.id) == nil
    end

    test "401 without a valid session", ctx do
      token = ctx.credentials.access_token
      _ = Accounts.revoke_session({:access, token})

      choose(token, %{context: "gym", gym_id: ctx.gym.id}) |> error(401, "unauthorized")
      entry(token, "?intent=gym") |> error(401, "unauthorized")
    end

    test "the choice survives a session refresh", ctx do
      204 = choose(ctx.credentials.access_token, %{context: "gym", gym_id: ctx.gym.id}).status

      refreshed =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/auth/session/refresh",
          Jason.encode!(%{refresh_token: ctx.credentials.refresh_token})
        )
        |> json_response(200)

      assert %{"destination" => "gym_home", "gym_id" => id} = entry!(refreshed["access_token"])
      assert id == ctx.gym.id
    end

    test "two devices share the account's preference; each request still names its own gym",
         ctx do
      other_gym = completed_gym!(registered!())
      staff!(other_gym.id, ctx.user, :front_desk)
      device_1 = ctx.credentials.access_token
      device_2 = session!(ctx.user).access_token

      204 = choose(device_1, %{context: "gym", gym_id: ctx.gym.id}).status
      assert entry!(device_2)["gym_id"] == ctx.gym.id

      # Device 2 works in the other gym explicitly; authorization follows the path.
      assert entry!(device_2, "?context=gym&gym_id=#{other_gym.id}")["gym_id"] == other_gym.id
      assert json_response(device_2 |> authed() |> get("/api/v1/gyms/#{other_gym.id}"), 200)
      assert json_response(device_1 |> authed() |> get("/api/v1/gyms/#{ctx.gym.id}"), 200)
    end

    test "logout racing a choice: the next request is 401 either way", ctx do
      token = ctx.credentials.access_token

      [chosen, _logout] =
        [
          fn -> choose(token, %{context: "gym", gym_id: ctx.gym.id}).status end,
          fn -> Accounts.revoke_session({:access, token}) end
        ]
        |> Enum.map(&Task.async/1)
        |> Task.await_many(10_000)

      assert chosen in [204, 401]
      entry(token) |> error(401, "unauthorized")
    end
  end
end
