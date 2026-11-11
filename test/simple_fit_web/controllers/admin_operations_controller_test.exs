defmodule SimpleFitWeb.AdminOperationsControllerTest do
  @moduledoc """
  SF-126 over HTTP, checked against OpenAPI: the measured system health page and the
  background job list and detail. Who may read what (`system.health.read`,
  `system.jobs.read`, nothing for product roles), every status from a real measurement
  (unknown and no-telemetry never healthy), job counts by real Oban state, and canaries
  proving arguments, `meta` and error messages never leave the database. No action
  exists to test.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.{Accounts, Operators, Repo}
  alias SimpleFit.Billing.Stripe.WebhookEvent
  alias SimpleFit.Observability.Operations
  alias SimpleFit.Operators.AuditEvent
  alias SimpleFitWeb.ApiSpec

  @admin "/api/v1/admin/operations"
  @canary "CANARY-7f3a"

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    :ok
  end

  defp operator!(permissions) do
    user = registered!("operator")
    {:ok, credentials} = Accounts.create_session(user)
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
    {:ok, credentials} = Accounts.create_session(user)

    {:ok, _} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => permissions})
      )

    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)
    %{user: user, token: credentials.access_token}
  end

  defp get_json(path, token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(path)

  # A job in `state`, with arguments, meta and an error that must never be shown.
  defp job!(worker, state, opts \\ []) do
    now = DateTime.utc_now()

    stamps =
      case state do
        "completed" -> [completed_at: now, attempted_at: now, attempt: 1]
        "discarded" -> [discarded_at: now, attempted_at: now, attempt: 3]
        "cancelled" -> [cancelled_at: now, attempted_at: now, attempt: 1]
        "executing" -> [attempted_at: now, attempt: 1]
        "retryable" -> [attempted_at: now, attempt: 1]
        "scheduled" -> [scheduled_at: DateTime.add(now, 3600)]
        _ -> []
      end

    errors =
      if state in ~w(discarded retryable cancelled) do
        [
          %{
            "at" => DateTime.to_iso8601(now),
            "attempt" => 1,
            "error" => "** (RuntimeError) #{@canary} failed for someone@example.com\n    stack"
          }
        ]
      else
        []
      end

    Repo.insert!(%Oban.Job{
      worker: worker,
      queue: Keyword.get(opts, :queue, "default"),
      args: %{"payload" => "#{@canary}-ARGS", "email" => "someone@example.com"},
      meta: %{"secret" => "#{@canary}-META"},
      state: state,
      max_attempts: 3,
      attempt: Keyword.get(stamps, :attempt, 0),
      errors: errors,
      inserted_at: now,
      scheduled_at: Keyword.get(stamps, :scheduled_at, now),
      attempted_at: Keyword.get(stamps, :attempted_at),
      completed_at: Keyword.get(stamps, :completed_at),
      discarded_at: Keyword.get(stamps, :discarded_at),
      cancelled_at: Keyword.get(stamps, :cancelled_at)
    })
  end

  defp check(body, id), do: Enum.find(body["health"]["checks"], &(&1["id"] == id))
  defp count(check, key), do: Enum.find_value(check["counts"], &(&1["key"] == key && &1["value"]))

  describe "who may read" do
    test "anonymous 401; a non-operator 404; each part needs its own permission" do
      for path <- ["#{@admin}/health", "#{@admin}/jobs", "#{@admin}/jobs/1"] do
        assert build_conn() |> get(path) |> json_response(401)

        {:ok, plain} = Accounts.create_session(registered!("plain"))

        assert %{"error" => %{"code" => "not_found"}} =
                 get_json(path, plain.access_token) |> json_response(404)
      end

      founder = operator!(["operators.manage"])

      assert %{"error" => %{"code" => "forbidden"}} =
               get_json("#{@admin}/health", founder.token) |> json_response(403)

      health = provisioned!(founder, ["system.health.read"])
      assert %{"health" => _} = get_json("#{@admin}/health", health.token) |> json_response(200)

      for path <- ["#{@admin}/jobs", "#{@admin}/jobs/1"] do
        assert %{"error" => %{"code" => "forbidden"}} =
                 get_json(path, health.token) |> json_response(403)
      end
    end

    test "a revoked grant stops the next read" do
      founder = operator!(["operators.manage"])
      reader = provisioned!(founder, ["system.health.read"])
      assert get_json("#{@admin}/health", reader.token) |> json_response(200)

      operator_id =
        Repo.one!(from(o in Operators.Operator, where: o.user_id == ^reader.user.id)).id

      {:ok, _} =
        act(founder.user, founder.session, "operator.permission.revoke", operator_id, %{
          "permission" => "system.health.read"
        })

      assert %{"error" => %{"code" => "forbidden"}} =
               get_json("#{@admin}/health", reader.token) |> json_response(403)
    end
  end

  describe "health" do
    test "every check is measured or says it isn't; nothing unknown reads as healthy" do
      op = operator!(["system.health.read"])
      response = get_json("#{@admin}/health", op.token)
      body = json_response(response, 200)
      assert_schema(body, "AdminOperationsHealthResponse", ApiSpec.spec())
      assert get_resp_header(response, "cache-control") == ["no-store"]

      assert %{"status" => "healthy", "observed_at" => observed} = check(body, "api")
      assert is_binary(observed)
      assert %{"status" => "healthy"} = database = check(body, "database")
      assert is_integer(count(database, "query_ms"))

      for id <- ~w(storage error_monitoring) do
        assert %{"status" => "no_telemetry", "observed_at" => nil} = check(body, id)
      end

      # Nothing sent and no webhook: unknown, never healthy.
      assert %{"status" => "unknown"} = check(body, "email")
      assert %{"status" => "unknown", "last_event_at" => nil} = check(body, "payments_webhooks")

      assert %{"applied" => applied, "latest_version" => latest} = body["health"]["migrations"]
      assert applied == length(Path.wildcard("priv/repo/migrations/*.exs"))
      assert latest == "20261205090000"
      assert %{"source" => "default", "release" => release} = body["health"]["release"]
      assert release =~ "simplefit-api@"
      refute response.resp_body =~ "postgres"
    end

    test "job, email and webhook statuses follow the real records" do
      op = operator!(["system.health.read"])
      mailer = "SimpleFit.Email.DeliveryWorker"
      job!(mailer, "completed", queue: "mailers")
      job!(mailer, "completed", queue: "mailers")
      job!("SimpleFit.Gyms.VerificationCleanupWorker", "scheduled")
      job!("SimpleFit.Gyms.VerificationCleanupWorker", "available")

      body = get_json("#{@admin}/health", op.token) |> json_response(200)
      assert %{"status" => "healthy"} = email = check(body, "email")
      assert count(email, "accepted_24h") == 2
      assert %{"status" => "healthy"} = jobs = check(body, "background_jobs")
      assert count(jobs, "waiting") == 2

      queues = Map.new(body["health"]["queues"], &{&1["name"], &1})

      assert %{"limit" => 10, "counts" => %{"available" => 1, "scheduled" => 1}} =
               queues["default"]

      assert %{"limit" => 5, "counts" => %{"completed" => 2, "discarded" => 0}} =
               queues["mailers"]

      job!(mailer, "discarded", queue: "mailers")

      Repo.insert!(%WebhookEvent{
        mode: :test,
        stripe_event_id: "evt_sf126",
        event_type: "invoice.paid",
        event_created_at: DateTime.utc_now(),
        status: :failed,
        attempts: 1
      })

      body = get_json("#{@admin}/health", op.token) |> json_response(200)
      assert %{"status" => "degraded"} = email = check(body, "email")
      assert count(email, "failed_24h") == 1
      assert %{"status" => "degraded"} = check(body, "background_jobs")
      assert %{"status" => "degraded", "last_event_at" => last} = check(body, "payments_webhooks")
      assert is_binary(last)
      assert count(check(body, "payments_webhooks"), "failed_24h") == 1
    end
  end

  describe "jobs" do
    test "metadata only: no arguments, meta or error message ever leaves; failure is the module" do
      op = operator!(["system.jobs.read"])
      job = job!("SimpleFit.Email.DeliveryWorker", "discarded", queue: "mailers")

      response = get_json("#{@admin}/jobs", op.token)
      body = json_response(response, 200)
      assert_schema(body, "AdminJobListResponse", ApiSpec.spec())
      refute response.resp_body =~ @canary
      refute response.resp_body =~ "someone@example.com"
      refute response.resp_body =~ "stack"

      assert [
               %{
                 "id" => id,
                 "failure" => "RuntimeError",
                 "errors" => 1,
                 "retry" => "not_supported"
               }
             ] =
               body["jobs"]

      assert id == job.id

      detail = get_json("#{@admin}/jobs/#{job.id}", op.token)
      assert_schema(json_response(detail, 200), "AdminJobResponse", ApiSpec.spec())
      refute detail.resp_body =~ @canary
      refute detail.resp_body =~ "someone@example.com"

      assert length(Repo.all(from(e in AuditEvent, where: e.action == "jobs.listed"))) == 1
      assert length(Repo.all(from(e in AuditEvent, where: e.action == "job.viewed"))) == 1

      assert %{"error" => %{"code" => "not_found"}} =
               get_json("#{@admin}/jobs/999999999", op.token) |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               get_json("#{@admin}/jobs/abc", op.token) |> json_response(404)
    end

    test "filters by state, queue and worker from fixed lists; bounded, keyset pages" do
      op = operator!(["system.jobs.read"])
      cleanup = "SimpleFit.Sponsors.EvidenceCleanupWorker"
      ids = for _ <- 1..5, do: job!(cleanup, "completed").id
      job!("SimpleFit.Email.DeliveryWorker", "retryable", queue: "mailers")

      ids_of = fn query ->
        (get_json("#{@admin}/jobs?#{query}", op.token) |> json_response(200))["jobs"]
        |> Enum.map(& &1["id"])
      end

      assert length(ids_of.("state=retryable")) == 1
      assert length(ids_of.("queue=mailers")) == 1
      assert ids_of.("worker=#{cleanup}") == Enum.reverse(ids)

      first = get_json("#{@admin}/jobs?worker=#{cleanup}&limit=2", op.token) |> json_response(200)

      second =
        get_json(
          "#{@admin}/jobs?worker=#{cleanup}&limit=2&cursor=#{first["next_cursor"]}",
          op.token
        )
        |> json_response(200)

      assert Enum.map(first["jobs"] ++ second["jobs"], & &1["id"]) ==
               ids |> Enum.reverse() |> Enum.take(4)

      for query <- [
            "state=failed",
            "queue=unknown",
            "worker=Elixir.System",
            "limit=51",
            "limit=0",
            "cursor=forged",
            "worker=#{cleanup}&cursor=#{first["next_cursor"]}&state=completed"
          ] do
        assert %{"error" => %{"code" => "validation_error"}} =
                 get_json("#{@admin}/jobs?#{query}", op.token) |> json_response(422)
      end
    end
  end

  describe "failure classification" do
    test "only a leading exception module is taken; anything else is nil" do
      assert Operations.failure([%{"error" => "** (Oban.PerformError) secret text"}]) ==
               "Oban.PerformError"

      assert Operations.failure([%{"error" => "plain message with user@example.com"}]) == nil
      assert Operations.failure([%{"error" => "** (lowercase) x"}]) == nil
      assert Operations.failure([]) == nil
      assert Operations.failure(nil) == nil
    end
  end
end
