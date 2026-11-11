defmodule SimpleFitWeb.AdminOversightControllerTest do
  @moduledoc """
  SF-123 over HTTP, checked against OpenAPI: operator oversight of gyms, coaches and
  fighters. Who may read what (one permission per domain, nothing for product
  roles), the gym list's filters and keyset pages, each detail's real counts and
  states, the reason recorded with each read, and canaries proving private fields
  (member names, business details, bio, body data, goals, training notes, account
  names) never appear.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.CoachingHelpers
  import SimpleFit.GymHelpers
  import SimpleFit.VerificationHelpers, only: [stub_storage: 1, submitted!: 2, approved!: 2]
  import SimpleFit.BookingHelpers, only: [member!: 3]
  import SimpleFit.TrainingHelpers, only: [assign!: 3]

  alias SimpleFit.{Accounts, Coaches, Coaching, Fighters, Operators, Repo}
  alias SimpleFit.Gyms.Gym
  alias SimpleFit.Operators.AuditEvent
  alias SimpleFitWeb.ApiSpec

  @admin "/api/v1/admin"
  @all ~w(gyms.read coaches.read fighters.read operators.manage users.restrict)

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    configure_sharing()
    stub_storage(%{})
    Repo.delete_all("rate_limit_events")
    :ok
  end

  defp credentials!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials
  end

  defp get_json(path, token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(path)

  defp operator!(permissions) do
    user = registered!("operator")
    credentials = credentials!(user)
    operator = bootstrap!(user, permissions)
    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)

    %{
      user: user,
      token: credentials.access_token,
      session: credentials.session,
      operator: operator
    }
  end

  defp provisioned!(founder, permissions) do
    user = registered!("reader")
    credentials = credentials!(user)

    {:ok, _} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => permissions})
      )

    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)
    %{user: user, token: credentials.access_token, session: credentials.session}
  end

  defp gyms(token, query \\ ""), do: get_json("#{@admin}/gyms?#{query}", token)

  defp gym(token, id, reason \\ "support_request"),
    do: get_json("#{@admin}/gyms/#{id}?reason_code=#{reason}", token)

  defp find(token, kind, query, reason \\ "support_request"),
    do:
      get_json(
        "#{@admin}/#{kind}?query=#{URI.encode_www_form(query)}&reason_code=#{reason}",
        token
      )

  defp profile(token, kind, id, reason \\ "support_request"),
    do: get_json("#{@admin}/#{kind}/#{id}?reason_code=#{reason}", token)

  defp audit(action), do: Repo.all(from(e in AuditEvent, where: e.action == ^action))

  # A gym with a name, created (inserted) at a known instant so paging order is fixed.
  defp named_gym!(name, at, opts \\ []) do
    owner = registered_as!(registered!("owner"), Keyword.get(opts, :owner, "Yauheni Bykovski"))

    gym =
      if opts[:draft],
        do: draft_gym!(owner, %{"name" => name}),
        else: completed_gym!(owner, %{"name" => name})

    {1, _} = Repo.update_all(from(g in Gym, where: g.id == ^gym.id), set: [inserted_at: at])
    {owner, gym}
  end

  # A coach and a fighter in two relationships (one ended), with a training note and
  # the fighter's private body data and goals: the canaries the views must never show.
  defp coaching! do
    coach = inviting_coach!("Coach Canary")
    {:ok, _} = Coaches.update_profile(coach, %{"bio" => "BIO-CANARY private story"})
    fighter = email_fighter!("fighter-#{System.unique_integer([:positive])}@example.com")

    {:ok, _} =
      Fighters.update_profile(fighter, %{
        "current_weight_kg" => "71.5",
        "height_cm" => 178,
        "weight_class" => "minus_71",
        "goals" => ["competition"],
        "next_fight_name" => "FIGHT-CANARY Cup"
      })

    relationship = activate!(coach, fighter)
    _ = assign!(coach, relationship.id, %{"notes" => "NOTE-CANARY jab work"})

    other = fighter_user!()
    ended = activate!(coach, other)
    :ok = Coaching.end_relationship(coach, :coach, ended.id)

    %{coach: coach, fighter: fighter, relationship: relationship}
  end

  describe "who may read" do
    test "anonymous 401; a gym owner, coach, fighter or sponsor gets the not-an-operator 404" do
      {owner, gym} = named_gym!("Owner Gym", DateTime.utc_now())
      %{coach: coach, fighter: fighter} = coaching!()
      coach_id = Coaches.get_profile(coach).id
      fighter_id = Fighters.get_profile(fighter).id

      paths = [
        "#{@admin}/gyms",
        "#{@admin}/gyms/#{gym.id}?reason_code=support_request",
        "#{@admin}/coaches?query=x&reason_code=support_request",
        "#{@admin}/coaches/#{coach_id}?reason_code=support_request",
        "#{@admin}/fighters?query=x&reason_code=support_request",
        "#{@admin}/fighters/#{fighter_id}?reason_code=support_request"
      ]

      for path <- paths, do: assert(build_conn() |> get(path) |> json_response(401))

      for user <- [owner, coach, fighter], path <- paths do
        assert %{"error" => %{"code" => "not_found"}} =
                 get_json(path, credentials!(user).access_token) |> json_response(404)
      end
    end

    test "each domain has its own permission, checked before any lookup (no existence oracle)" do
      founder = operator!(["operators.manage"])
      gyms_only = provisioned!(founder, ["gyms.read"])
      {_owner, gym} = named_gym!("Scoped Gym", DateTime.utc_now())
      %{coach: coach, fighter: fighter} = coaching!()
      coach_id = Coaches.get_profile(coach).id
      fighter_id = Fighters.get_profile(fighter).id
      missing = Ecto.UUID.generate()

      assert %{"gyms" => [_ | _]} = gyms(gyms_only.token) |> json_response(200)
      assert %{"gym" => _} = gym(gyms_only.token, gym.id) |> json_response(200)

      for {kind, id} <- [{"coaches", coach_id}, {"fighters", fighter_id}],
          target <- [id, missing] do
        assert %{"error" => %{"code" => "forbidden"}} =
                 profile(gyms_only.token, kind, target) |> json_response(403)

        assert %{"error" => %{"code" => "forbidden"}} =
                 find(gyms_only.token, kind, coach.id) |> json_response(403)
      end

      coaches_only = provisioned!(founder, ["coaches.read"])

      assert %{"coaches" => [_]} =
               find(coaches_only.token, "coaches", coach.id) |> json_response(200)

      for target <- [gym.id, missing] do
        assert %{"error" => %{"code" => "forbidden"}} =
                 gym(coaches_only.token, target) |> json_response(403)
      end

      assert %{"error" => %{"code" => "forbidden"}} =
               profile(coaches_only.token, "fighters", fighter_id) |> json_response(403)

      # Refusals are recorded with the permission that was missing.
      assert Enum.any?(
               Repo.all(from(e in AuditEvent, where: e.outcome == :refused)),
               &(&1.permission == "gyms.read")
             )
    end

    test "a revoked grant or a suspended operator stops reads at once" do
      founder = operator!(["operators.manage"])
      reader = provisioned!(founder, ["gyms.read"])
      {_owner, gym} = named_gym!("Revoked Gym", DateTime.utc_now())
      assert %{"gym" => _} = gym(reader.token, gym.id) |> json_response(200)

      {:ok, _} =
        act(
          founder.user,
          founder.session,
          "operator.permission.revoke",
          reader_operator(reader),
          %{
            "permission" => "gyms.read"
          }
        )

      assert %{"error" => %{"code" => "forbidden"}} =
               gym(reader.token, gym.id) |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} = gyms(reader.token) |> json_response(403)
    end
  end

  defp reader_operator(reader),
    do: Repo.one!(from(o in SimpleFit.Operators.Operator, where: o.user_id == ^reader.user.id)).id

  describe "gym list" do
    test "real gyms, newest first, in stable keyset pages; each query recorded" do
      op = operator!(@all)
      base = ~U[2026-11-01 10:00:00.000000Z]

      ids =
        for n <- 1..5 do
          {_owner, gym} = named_gym!("Paging Gym #{n}", DateTime.add(base, n, :minute))
          gym.id
        end

      # Two gyms at the same instant: the id breaks the tie.
      {_o, twin} = named_gym!("Paging Gym 6", DateTime.add(base, 5, :minute))
      [g1, g2, g3, g4, g5] = ids
      expected = Enum.sort([g5, twin.id], :desc) ++ [g4, g3, g2, g1]

      pages =
        Stream.unfold(nil, fn
          :done ->
            nil

          cursor ->
            query = "query=Paging%20Gym&limit=2" <> if(cursor, do: "&cursor=#{cursor}", else: "")
            body = gyms(op.token, query) |> json_response(200)
            assert_schema(body, "AdminGymListResponse", ApiSpec.spec())
            {body["gyms"], body["next_cursor"] || :done}
        end)
        |> Enum.to_list()

      assert length(pages) == 3
      assert Enum.map(List.flatten(pages), & &1["id"]) == expected
      assert length(audit("gyms.listed")) == 3
    end

    test "filters: name prefix (case-insensitive, wildcards literal), lifecycle, verification, country" do
      op = operator!(@all)
      now = DateTime.utc_now()
      {owner1, approved} = named_gym!("Filter Alpha", now)
      {owner2, submitted} = named_gym!("Filter Beta", now)
      {_o3, draft} = named_gym!("Filter_Draft", now, draft: true)
      approved!(owner1, approved.id)
      submitted!(owner2, submitted.id)

      ids = fn query ->
        body = gyms(op.token, query) |> json_response(200)
        Enum.map(body["gyms"], & &1["id"]) |> MapSet.new()
      end

      assert ids.("query=filter") == MapSet.new([approved.id, submitted.id, draft.id])
      assert ids.("query=FILTER%20A") == MapSet.new([approved.id])
      assert ids.("query=filter_") == MapSet.new([draft.id])
      assert ids.("query=filter%25") == MapSet.new()
      assert ids.("query=filter&lifecycle=draft") == MapSet.new([draft.id])
      assert ids.("query=filter&verification=approved") == MapSet.new([approved.id])
      assert ids.("query=filter&verification=submitted") == MapSet.new([submitted.id])
      assert ids.("query=filter&verification=not_started") == MapSet.new([draft.id])
      assert ids.("query=filter&country=PL") == MapSet.new([approved.id, submitted.id])
      assert ids.("query=filter&country=DE") == MapSet.new()

      [row] = (gyms(op.token, "query=Filter%20Alpha") |> json_response(200))["gyms"]

      assert %{
               "lifecycle" => "completed",
               "verification_status" => "approved",
               "country_code" => "PL",
               "city" => "Kraków",
               "staff_count" => 1
             } = row
    end

    test "bounded and validated: limit, enums, country, empty query, cursor bound to its filters" do
      op = operator!(@all)
      for n <- 1..3, do: named_gym!("Bound #{n}", DateTime.utc_now())

      for query <- [
            "limit=51",
            "limit=0",
            "lifecycle=suspended",
            "verification=verified",
            "country=pl",
            "query=",
            "cursor=forged"
          ] do
        assert %{"error" => %{"code" => "validation_error"}} =
                 gyms(op.token, query) |> json_response(422)
      end

      %{"next_cursor" => cursor} = gyms(op.token, "query=Bound&limit=1") |> json_response(200)
      assert is_binary(cursor)

      assert %{"error" => %{"code" => "validation_error"}} =
               gyms(op.token, "query=Bou&limit=1&cursor=#{cursor}") |> json_response(422)

      other = provisioned!(op, ["gyms.read"])

      assert %{"error" => %{"code" => "validation_error"}} =
               gyms(other.token, "query=Bound&limit=1&cursor=#{cursor}") |> json_response(422)
    end
  end

  describe "gym detail" do
    test "people as counts plus the owner's short name; verification status only; reason recorded" do
      op = operator!(@all)
      {owner, gym} = named_gym!("Detail Gym", DateTime.utc_now(), owner: "Natalia Wiśniewska")
      submitted!(owner, gym.id)
      staff!(gym.id, registered_as!(registered!("mgr"), "STAFF-CANARY Name"), :manager)
      staff!(gym.id, registered!("coach"), :coach)
      staff!(gym.id, registered!("coach"), :coach)
      {_member, _} = member!(owner, gym.id, "MEMBER-CANARY Kowalska")

      response = gym(op.token, gym.id, "abuse_report")
      body = json_response(response, 200)
      assert_schema(body, "AdminGymResponse", ApiSpec.spec())

      assert %{
               "name" => "Detail Gym",
               "lifecycle" => "completed",
               "owner" => %{"user_id" => owner_id, "short_name" => "Natalia W."},
               "staff" => %{"manager" => 1, "coach" => 2, "front_desk" => 0},
               "staff_count" => 4,
               "members" => %{"active" => 1, "requested" => 0},
               "verification" => %{"status" => "submitted", "revision" => revision}
             } = body["gym"]

      assert owner_id == owner.id
      assert is_integer(revision)

      raw = response.resp_body

      for canary <- [
            "Wiśniewska",
            "STAFF-CANARY",
            "MEMBER-CANARY",
            "Kowalska",
            "registry-extract",
            "ul. ",
            "@example.com",
            "legal_name"
          ] do
        refute raw =~ canary
      end

      assert [%{reason_code: "abuse_report", target_type: "gym", target_id: target}] =
               audit("gym.viewed")

      assert target == gym.id
    end

    test "a draft gym without location or verification; unknown, malformed or reasonless reads" do
      op = operator!(@all)
      {_owner, draft} = named_gym!("Draft Detail", DateTime.utc_now(), draft: true)

      assert %{
               "gym" => %{
                 "lifecycle" => "draft",
                 "country_code" => nil,
                 "verification" => %{"status" => "not_started", "revision" => nil}
               }
             } = gym(op.token, draft.id) |> json_response(200)

      assert %{"error" => %{"code" => "not_found"}} =
               gym(op.token, Ecto.UUID.generate()) |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} = gym(op.token, "nope") |> json_response(404)

      assert %{"error" => %{"code" => "validation_error"}} =
               get_json("#{@admin}/gyms/#{draft.id}", op.token) |> json_response(422)

      assert %{"error" => %{"code" => "validation_error"}} =
               gym(op.token, draft.id, "curiosity") |> json_response(422)
    end
  end

  describe "coaches" do
    test "exact lookup by email or user id; partial never matches; every search recorded" do
      op = operator!(@all)
      address = "coach-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.register_user(:email, address)
      coach = user |> registered_as!("Marek Nowak") |> complete_coach!("Coach Exact")
      profile_id = Coaches.get_profile(coach).id

      for query <- [address, String.upcase(address), coach.id] do
        body = find(op.token, "coaches", query) |> json_response(200)
        assert_schema(body, "AdminCoachSearchResponse", ApiSpec.spec())

        assert [
                 %{
                   "id" => ^profile_id,
                   "display_name" => "Coach Exact",
                   "account_status" => "active"
                 }
               ] =
                 body["coaches"]
      end

      for query <- ["coach", "Coach Exact", String.slice(address, 0, 8), "%"] do
        assert %{"coaches" => []} = find(op.token, "coaches", query) |> json_response(200)
      end

      # A person without a coach profile is not a coach.
      assert %{"coaches" => []} =
               find(op.token, "coaches", registered!("plain").id) |> json_response(200)

      assert length(audit("coach.searched")) == 8

      assert %{"error" => %{"code" => "validation_error"}} =
               get_json("#{@admin}/coaches?query=#{coach.id}", op.token) |> json_response(422)
    end

    test "detail: profile and account state apart, counts only, gym ids, never the bio or notes" do
      op = operator!(@all)
      %{coach: coach} = coaching!()
      profile_id = Coaches.get_profile(coach).id
      {_owner, gym} = named_gym!("Coach's Gym", DateTime.utc_now())
      staff!(gym.id, coach, :coach)

      {:ok, _} = act(op.user, op.session, "user.suspend", coach.id)

      response = profile(op.token, "coaches", profile_id, "legal_request")
      body = json_response(response, 200)
      assert_schema(body, "AdminCoachResponse", ApiSpec.spec())

      assert %{
               "profile_status" => "completed",
               "account_status" => "suspended",
               "relationships" => %{"active" => 1, "ended" => 1, "invitations_pending" => 0},
               "gyms" => [%{"gym_id" => gym_id}]
             } = body["coach"]

      assert gym_id == gym.id

      for canary <- ["BIO-CANARY", "NOTE-CANARY", "Alex K.", "fighter_", "Jab", "Coach's Gym"] do
        refute response.resp_body =~ canary
      end

      assert [%{reason_code: "legal_request", target_type: "coach_profile"}] =
               audit("coach.viewed")

      # The gym id leads to the gym only with gyms.read.
      reader = provisioned!(op, ["coaches.read"])
      assert %{"coach" => _} = profile(reader.token, "coaches", profile_id) |> json_response(200)

      assert %{"error" => %{"code" => "forbidden"}} =
               gym(reader.token, gym.id) |> json_response(403)
    end
  end

  test "reads are current: an ended relationship or a deleted profile shows on the next read" do
    op = operator!(@all)
    %{coach: coach, relationship: relationship} = coaching!()
    profile_id = Coaches.get_profile(coach).id

    assert %{"coach" => %{"relationships" => %{"active" => 1, "ended" => 1}}} =
             profile(op.token, "coaches", profile_id) |> json_response(200)

    :ok = Coaching.end_relationship(coach, :coach, relationship.id)

    assert %{"coach" => %{"relationships" => %{"active" => 0, "ended" => 2}}} =
             profile(op.token, "coaches", profile_id) |> json_response(200)

    Repo.delete_all(from(p in SimpleFit.Coaches.CoachProfile, where: p.id == ^profile_id))

    assert %{"error" => %{"code" => "not_found"}} =
             profile(op.token, "coaches", profile_id) |> json_response(404)
  end

  describe "fighters" do
    test "exact lookup by @username (any case), email or user id" do
      op = operator!(@all)
      %{fighter: fighter} = coaching!()
      profile = Fighters.get_profile(fighter)
      email = hd(Accounts.admin_view(fighter.id).email_addresses)

      for query <- [
            "@" <> profile.username,
            "@" <> String.upcase(profile.username),
            email,
            fighter.id
          ] do
        body = find(op.token, "fighters", query) |> json_response(200)
        assert_schema(body, "AdminFighterSearchResponse", ApiSpec.spec())
        assert [%{"id" => id, "active_relationships" => 1}] = body["fighters"]
        assert id == profile.id
      end

      for query <- [profile.username, "@" <> String.slice(profile.username, 0, 5), "@%"] do
        assert %{"fighters" => []} = find(op.token, "fighters", query) |> json_response(200)
      end
    end

    test "detail: shared fields and counts; never body data, goals, fights, age, names or notes" do
      op = operator!(@all)
      %{fighter: fighter} = coaching!()
      registered_as!(fighter, "ACCOUNT-CANARY Name")
      profile_id = Fighters.get_profile(fighter).id

      response = profile(op.token, "fighters", profile_id)
      body = json_response(response, 200)
      assert_schema(body, "AdminFighterResponse", ApiSpec.spec())

      assert %{
               "display_name" => "Alex K.",
               "experience_level" => "amateur",
               "stance" => "orthodox",
               "profile_status" => "completed",
               "account_status" => "active",
               "relationships" => %{"active" => 1, "ended" => 0},
               "gym_memberships" => 0
             } = body["fighter"]

      for canary <- [
            "71.5",
            "178",
            "minus_71",
            "competition",
            "FIGHT-CANARY",
            "NOTE-CANARY",
            "ACCOUNT-CANARY",
            "date_of_birth",
            "Coach Canary",
            "@example.com"
          ] do
        refute response.resp_body =~ canary
      end

      for key <-
            ~w(current_weight_kg height_cm weight_class goals next_fight_on amateur_bout_count) do
        refute Map.has_key?(body["fighter"], key)
      end

      assert [%{target_type: "fighter_profile"}] = audit("fighter.viewed")
    end

    test "searches share a per-operator hourly limit" do
      op = operator!(@all)

      for _ <- 1..60 do
        assert %{"fighters" => []} = find(op.token, "fighters", "@nobody") |> json_response(200)
      end

      assert %{"error" => %{"code" => "rate_limited"}} =
               find(op.token, "coaches", "nobody@example.com") |> json_response(429)
    end
  end
end
