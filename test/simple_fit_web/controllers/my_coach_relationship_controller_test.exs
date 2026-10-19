defmodule SimpleFitWeb.MyCoachRelationshipControllerTest do
  @moduledoc """
  `getMyCoachRelationship` over HTTP (SF-74): the fighter's own relationship
  by id, OpenAPI schemas, multi-account authorization (IDOR), revoked
  sessions, the sharing gate and privacy (canaries planted in coach and
  fighter private data never reach a response or a log).
  """

  # Not async: the sharing gate is global configuration.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers

  alias SimpleFit.{Accounts, Coaches, Coaching, Fighters}
  alias SimpleFitWeb.ApiSpec

  @canary "CANARYsf74rel5Tn8Hb3Lc6"

  setup do
    configure_sharing()
    :ok
  end

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp show(who, id, query \\ "")

  defp show(%Accounts.User{} = user, id, query), do: show(token(user), id, query)

  defp show(token, id, query) when is_binary(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/api/v1/me/coaches/#{id}" <> query)
  end

  defp list(user, query),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token(user))
      |> get("/api/v1/me/coaches" <> query)

  defp ok!(conn) do
    body = json_response(conn, 200)
    assert_schema(body, "MyCoachRelationshipResponse", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body["relationship"]
  end

  defp not_found!(conn) do
    body = json_response(conn, 404)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    assert body["error"]["code"] == "not_found"
    conn.resp_body
  end

  # A coach whose private account data carries canaries.
  defp planted_coach! do
    {:ok, user} = Accounts.register_user(:email, "coach-#{String.downcase(@canary)}@example.com")

    {:ok, _} =
      Accounts.update_account_registration(user, %{
        "full_name" => "Private #{@canary} Coach",
        "date_of_birth" => "1980-02-29",
        "accept_terms" => true,
        "accept_privacy" => true
      })

    {:ok, _} = Accounts.complete_account_registration(user)
    complete_coach!(user, "Coach Marek")
  end

  # A fighter whose private profile data carries canaries.
  defp planted_fighter! do
    user = fighter_user!()

    {:ok, _} =
      Fighters.update_profile(user, %{
        "next_fight_name" => "Fight #{@canary} Night",
        "current_weight_kg" => "66.6",
        "height_cm" => 177,
        "weight_class" => "minus_67"
      })

    user
  end

  @private_keys ~w(email full_name date_of_birth user_id coach_profile_id fighter_profile_id
                   identities next_fight_name current_weight_kg height_cm weight_class goals
                   recipient_digest token_hash)

  defp refute_private!(raw) do
    refute raw =~ @canary
    refute raw =~ String.downcase(@canary)
    refute raw =~ "1980-02-29"
    for key <- @private_keys, do: refute(raw =~ ~s("#{key}"), "response has #{key}")
  end

  describe "the fighter's own relationship" do
    setup do
      coach = planted_coach!()
      fighter = planted_fighter!()
      %{coach: coach, fighter: fighter, r: activate!(coach, fighter)}
    end

    test "active: 200, no-store, the same entry as listMyCoaches, nothing private", %{
      fighter: fighter,
      r: r
    } do
      conn = show(fighter, r.id)
      entry = ok!(conn)

      assert entry["relationship_id"] == r.id
      assert entry["status"] == "active"
      assert entry["coach"] == %{"display_name" => "Coach Marek", "brand_name" => "Marek Boxing"}
      assert entry["coach_display_name_at_end"] == nil
      assert [entry] == json_response(list(fighter, ""), 200)["relationships"]
      refute_private!(conn.resp_body)
    end

    test "ended: the historical stub with the name at the end, not the current profile", %{
      coach: coach,
      fighter: fighter,
      r: r
    } do
      :ok = Coaching.end_relationship(fighter, :fighter, r.id)
      {:ok, _} = Coaches.update_profile(coach, %{"display_name" => "Coach Renamed"})

      conn = show(fighter, r.id)
      entry = ok!(conn)

      assert entry["status"] == "ended"
      assert entry["coach"] == nil
      assert entry["coach_display_name_at_end"] == "Coach Marek"
      assert entry["ended_by"] == "fighter"
      assert is_binary(entry["ended_at"])
      assert entry["disclosed_fields"] == []
      assert [entry] == json_response(list(fighter, "?status=ended"), 200)["relationships"]
      refute conn.resp_body =~ "Coach Renamed"
      refute_private!(conn.resp_body)
    end

    test "query parameters cannot widen access", %{coach: coach, fighter: fighter, r: r} do
      other = fighter_user!()
      theirs = activate!(coach_user!("Coach B"), other)
      fighter_profile = Fighters.get_profile(other).id

      for query <- [
            "?fighter_profile_id=#{fighter_profile}",
            "?user_id=#{other.id}",
            "?coach_profile_id=#{Coaches.get_profile(coach).id}",
            "?status=ended&role=coach"
          ] do
        not_found!(show(fighter, theirs.id, query))
        assert ok!(show(fighter, r.id, query))["relationship_id"] == r.id
      end
    end

    test "the sharing gate off: still readable by its fighter, never by the coach", %{
      coach: coach,
      fighter: fighter,
      r: r
    } do
      set_sharing(enabled: false, disclosures: %{}, current: nil)

      assert ok!(show(fighter, r.id))["status"] == "active"
      not_found!(show(coach, r.id))
    end
  end

  describe "authorization" do
    test "foreign, unknown and malformed ids answer the same 404 without echoing the id" do
      coach = coach_user!()
      fighter_a = fighter_user!()
      fighter_b = fighter_user!()
      theirs = activate!(coach, fighter_b)
      dual = fighter_user!() |> complete_coach!("Dual")
      dual_as_coach = activate!(dual, fighter_user!())
      no_profile = registered_user!("nofighter")

      for who <- [fighter_a, coach, dual, no_profile],
          id <- [theirs.id, Ecto.UUID.generate(), "not-a-uuid", "%27%20OR%201%3D1", "A"] do
        raw = not_found!(show(who, id))
        refute raw =~ theirs.id
      end

      # The coach side of the dual-role user is not readable as fighter.
      not_found!(show(dual, dual_as_coach.id))

      long = String.duplicate("a", 5_000)
      conn = show(fighter_a, long)
      assert conn.status == 404
    end

    test "unauthenticated and revoked sessions answer 401" do
      coach = coach_user!()
      fighter = fighter_user!()
      r = activate!(coach, fighter)

      conn = get(build_conn(), "/api/v1/me/coaches/#{r.id}")
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"

      access = token(fighter)
      assert ok!(show(access, r.id))["relationship_id"] == r.id
      :ok = Accounts.revoke_session({:access, access})
      assert json_response(show(access, r.id), 401)["error"]["code"] == "unauthorized"
    end

    test "GET never creates, edits or ends anything" do
      coach = coach_user!()
      fighter = fighter_user!()
      r = activate!(coach, fighter)
      before = SimpleFit.Repo.get!(SimpleFit.Coaching.Relationship, r.id)

      for _ <- 1..3, do: ok!(show(fighter, r.id))

      assert SimpleFit.Repo.get!(SimpleFit.Coaching.Relationship, r.id) == before
      assert SimpleFit.Repo.aggregate(SimpleFit.Coaching.Relationship, :count) == 1
    end
  end

  test "canaries in ids and query parameters never echo, log or 5xx" do
    coach = planted_coach!()
    fighter = planted_fighter!()
    r = activate!(coach, fighter)
    access = token(fighter)

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      capture_log([level: :debug], fn ->
        for id <- [URI.encode_www_form(@canary), "#{r.id}#{@canary}", r.id],
            query <- [
              "",
              "?x=#{@canary}",
              "?user_id=#{URI.encode_www_form(String.downcase(@canary))}%40example.com",
              "?nested[deep]=sfi_#{@canary}"
            ] do
          conn = show(access, id, query)
          assert conn.status in [200, 404]
          refute_private!(conn.resp_body)
        end
      end)

    refute log =~ @canary
    refute log =~ String.downcase(@canary)
    refute log =~ access
  end
end
