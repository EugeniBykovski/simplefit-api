defmodule SimpleFitWeb.AdminOverviewControllerTest do
  @moduledoc """
  SF-121 over HTTP, checked against OpenAPI: `GET /api/v1/admin/overview` for every
  kind of caller, per-permission sections (a missing permission is `restricted`,
  never zero), counts that don't double-count overlapping contexts, the period
  parameter, and responses that carry no name, address or identifier.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.SponsorHelpers, only: [provision!: 1, member!: 3, org_attrs: 1]

  import SimpleFit.GymHelpers,
    only: [registered!: 1, email_user!: 1, completed_gym!: 1, draft_gym!: 1]

  import SimpleFit.CoachingHelpers, only: [complete_coach!: 1]
  import SimpleFit.FighterOnboardingHelpers, only: [complete_fighter_onboarding!: 1]

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Operators.{AuditEvent, Operator}
  alias SimpleFit.Sponsors.Provisioning
  alias SimpleFitWeb.ApiSpec

  @path "/api/v1/admin/overview"
  @all ~w(platform.dashboard.read operators.read sponsors.applications.read system.health.read)

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    :ok
  end

  defp session!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    {credentials.access_token, credentials.session}
  end

  defp get_overview(token, query \\ ""),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(@path <> query)

  # An operator with `permissions` and a key check in its session.
  defp operator!(permissions, prefix \\ "operator") do
    user = registered!(prefix)
    {token, session} = session!(user)
    operator = bootstrap!(user, permissions)
    [key | _] = enroll!(user, session)
    _ = step_up!(user, session, key)
    %{user: user, token: token, operator: operator}
  end

  defp overview!(token, query \\ "") do
    body = get_overview(token, query) |> json_response(200)
    assert_schema(body, "AdminOverviewResponse", ApiSpec.spec())
    body["overview"]
  end

  defp metric(overview, id), do: Enum.find(overview["metrics"], &(&1["id"] == id))
  defp counts(list), do: Map.new(list, &{&1["key"], &1["value"]})

  # An organization provisioned from an approved application (as SF-116 does it).
  defp approved_org!(owner) do
    app = submitted!(owner, draft!(owner))
    review!(app, :under_review)
    review!(app, :approved)

    {:ok, org} =
      Repo.transaction(fn ->
        {:ok, authority} = Provisioning.application_authority(app.id)

        {:ok, %{organization: org}} =
          Provisioning.provision_organization(authority, org_attrs(owner))

        org
      end)

    org
  end

  describe "who may read it" do
    test "anonymous: 401" do
      assert build_conn() |> get(@path) |> json_response(401)
    end

    test "an ordinary user, a sponsor member and a gym owner: the same 404 as an unknown route" do
      plain = registered!("plain")
      sponsor = registered!("sponsor-owner")
      provision!(sponsor)
      gym_owner = registered!("gym-owner")
      completed_gym!(gym_owner)

      for user <- [plain, sponsor, gym_owner] do
        {token, _} = session!(user)
        assert %{"error" => %{"code" => "not_found"}} = get_overview(token) |> json_response(404)
      end
    end

    test "a pending operator: enrollment_required; no key check: step_up_required" do
      pending = registered!("pending")
      {pending_token, _} = session!(pending)
      _ = bootstrap!(pending, ["platform.dashboard.read"])

      assert %{"error" => %{"code" => "enrollment_required"}} =
               get_overview(pending_token) |> json_response(403)
    end

    test "an active operator without a key check in this session: step_up_required" do
      user = registered!("unchecked")
      {token, session} = session!(user)
      _ = bootstrap!(user, ["platform.dashboard.read"])
      _ = enroll!(user, session)

      assert %{"error" => %{"code" => "step_up_required"}} =
               get_overview(token) |> json_response(403)
    end

    test "an operator with none of the overview's permissions: forbidden, and the refusal is audited" do
      op = operator!(["audit.read"])

      assert %{"error" => %{"code" => "forbidden"}} = get_overview(op.token) |> json_response(403)

      assert Repo.exists?(
               from(e in AuditEvent,
                 where:
                   e.action == "operator.access_refused" and
                     e.actor_operator_id == ^op.operator.id and
                     e.permission == "platform.dashboard.read"
               )
             )
    end

    test "a revoked operator, with the same session and key check: 404" do
      op = operator!(@all)
      assert overview!(op.token)

      Repo.update_all(from(o in Operator, where: o.id == ^op.operator.id),
        set: [status: :revoked, revoked_at: DateTime.utc_now()]
      )

      assert %{"error" => %{"code" => "not_found"}} = get_overview(op.token) |> json_response(404)
    end

    test "a successful read isn't audited per load (counts only, SF-107)" do
      op = operator!(@all)
      before = Repo.aggregate(AuditEvent, :count)
      _ = overview!(op.token)
      _ = overview!(op.token, "?period=30d")
      assert Repo.aggregate(AuditEvent, :count) == before
    end
  end

  describe "sections follow permissions" do
    test "the dashboard alone: platform counts; operators, the review queue and health are restricted" do
      op = operator!(["platform.dashboard.read"])
      overview = overview!(op.token)

      for id <- ~w(accounts fighter_profiles coach_profiles gyms sponsor_organizations) do
        assert %{"state" => "available", "value" => value} = metric(overview, id)
        assert is_integer(value)
      end

      for id <- ~w(operators sponsor_applications_waiting) do
        assert %{
                 "state" => "restricted",
                 "value" => nil,
                 "breakdown" => [],
                 "period_counts" => []
               } =
                 metric(overview, id)
      end

      assert %{"state" => "restricted", "checks" => []} = overview["health"]
    end

    test "a reviewer: the review queue only; platform counts are restricted, not zero" do
      op = operator!(["sponsors.applications.read"], "reviewer")
      overview = overview!(op.token)

      assert %{"state" => "available"} = metric(overview, "sponsor_applications_waiting")

      for id <- ~w(accounts fighter_profiles coach_profiles gyms sponsor_organizations operators) do
        assert %{"state" => "restricted", "value" => nil} = metric(overview, id)
      end

      assert overview["health"]["state"] == "restricted"
    end

    test "health only: real checks; nothing called healthy without a check" do
      op = operator!(["system.health.read"], "health")
      overview = overview!(op.token)

      assert Enum.all?(overview["metrics"], &(&1["state"] in ["restricted", "unavailable"]))

      assert %{
               "database" => %{"status" => "healthy"},
               "background_jobs" => %{"status" => "healthy", "counts" => jobs},
               "payments_webhooks" => %{"status" => "unknown", "last_event_at" => nil},
               "email_provider" => %{"status" => "no_telemetry"}
             } = Map.new(overview["health"]["checks"], &{&1["id"], &1})

      assert %{"waiting" => _, "discarded_24h" => 0} = counts(jobs)
    end

    test "a discarded job in the last 24 hours makes background jobs degraded" do
      op = operator!(["system.health.read"], "health")

      Repo.insert_all(Oban.Job, [
        %{
          worker: "SimpleFit.Email.DeliveryWorker",
          queue: "mailers",
          args: %{},
          state: "discarded",
          attempted_at: DateTime.utc_now(),
          discarded_at: DateTime.utc_now()
        }
      ])

      checks = Map.new(overview!(op.token)["health"]["checks"], &{&1["id"], &1})
      assert %{"status" => "degraded", "counts" => counts} = checks["background_jobs"]
      assert counts(counts)["discarded_24h"] == 1
    end

    test "gym verifications are unavailable, never zero, for any operator" do
      op = operator!(@all)

      assert %{"state" => "unavailable", "value" => nil} =
               metric(overview!(op.token), "gym_verifications_waiting")
    end
  end

  describe "counts" do
    test "an empty platform is zero (a real zero), with the operator itself counted" do
      op = operator!(@all)
      overview = overview!(op.token)

      # The operator's own account is registered; nothing else exists.
      assert %{"value" => 1} = metric(overview, "accounts")

      for id <-
            ~w(fighter_profiles coach_profiles gyms sponsor_organizations sponsor_applications_waiting) do
        assert %{"state" => "available", "value" => 0} = metric(overview, id)
      end

      assert %{"value" => 1} = metric(overview, "operators")
    end

    test "overlapping contexts: one user is one account, one fighter, one coach" do
      op = operator!(@all)
      base = overview!(op.token)

      # One user who is a fighter, a coach, owns a gym and belongs to two organizations.
      person = registered!("multi")
      complete_fighter_onboarding!(person)
      complete_coach!(person)
      completed_gym!(person)
      draft_owner = registered!("draft-owner")
      draft_gym!(draft_owner)
      org_a = approved_org!(person)
      other_owner = registered!("other-owner")
      org_b = approved_org!(other_owner)
      member!(org_b, person, :member)
      for n <- 1..3, do: member!(org_a, registered!("member-#{n}"), :member)

      overview = overview!(op.token)
      delta = fn id -> metric(overview, id)["value"] - metric(base, id)["value"] end

      # person, draft_owner, other_owner and three members: six new accounts.
      assert delta.("accounts") == 6
      assert delta.("fighter_profiles") == 1
      assert delta.("coach_profiles") == 1
      assert delta.("gyms") == 1
      assert counts(metric(overview, "gyms")["breakdown"])["draft"] == 1
      # Two organizations, however many members.
      assert delta.("sponsor_organizations") == 2
      assert org_a.id != org_b.id
    end

    test "applications and organizations are counted apart; drafts and fixtures aren't counted" do
      op = operator!(@all)

      draft!(registered!("drafting"))
      applicant = email_user!("waiting@example.com")
      waiting = submitted!(applicant, draft!(applicant))
      review!(waiting, :under_review)
      fresh = registered!("fresh")
      _submitted = submitted!(fresh, draft!(fresh))
      approved_owner = registered!("approved")
      approved_org!(approved_owner)
      provision!(registered!("fixture"))

      overview = overview!(op.token)
      apps = metric(overview, "sponsor_applications_waiting")
      by_status = counts(apps["breakdown"])

      assert apps["value"] == by_status["submitted"] + by_status["under_review"]
      assert by_status["approved"] == 1
      refute Map.has_key?(by_status, "draft")
      assert counts(apps["period_counts"])["approved"] == 1

      # The approved application's organization counts once, the fixture organization not at all.
      orgs = metric(overview, "sponsor_organizations")
      assert orgs["value"] == 1
      assert counts(orgs["period_counts"])["approved"] == 1
    end

    test "an incomplete registration is an account in progress, not a registered one" do
      op = operator!(@all)
      base = overview!(op.token)
      {:ok, _bare} = Accounts.register_user(:google, "bare-#{System.unique_integer([:positive])}")

      overview = overview!(op.token)
      assert metric(overview, "accounts")["value"] == metric(base, "accounts")["value"]

      assert counts(metric(overview, "accounts")["breakdown"])["not_started"] ==
               counts(metric(base, "accounts")["breakdown"])["not_started"] + 1
    end
  end

  describe "period and privacy" do
    test "24h, 7d (default) and 30d windows end at as_of; anything else is a validation error" do
      op = operator!(@all)

      for {query, key, seconds} <- [
            {"", "7d", 7 * 86_400},
            {"?period=24h", "24h", 86_400},
            {"?period=30d", "30d", 30 * 86_400}
          ] do
        %{"as_of" => as_of, "period" => period} = overview!(op.token, query)
        assert period["key"] == key
        assert period["to"] == as_of
        {:ok, from, _} = DateTime.from_iso8601(period["from"])
        {:ok, to, _} = DateTime.from_iso8601(period["to"])
        assert DateTime.diff(to, from) == seconds
      end

      for bad <- ["?period=1y", "?period=", "?period=7D"] do
        assert %{"error" => %{"code" => "validation_error"}} =
                 get_overview(op.token, bad) |> json_response(422)
      end
    end

    test "the response carries no name, address or identifier of anyone" do
      op = operator!(@all)
      person = email_user!("canary.person@example.com")
      complete_fighter_onboarding!(person)
      org = approved_org!(person)

      raw = get_overview(op.token) |> response(200)

      for secret <- [
            "canary.person@example.com",
            "Natalia",
            person.id,
            org.id,
            org.display_name,
            op.user.id,
            op.operator.id
          ] do
        refute raw =~ secret
      end
    end
  end
end
