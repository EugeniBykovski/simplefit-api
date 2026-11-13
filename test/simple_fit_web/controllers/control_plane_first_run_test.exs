defmodule SimpleFitWeb.ControlPlaneFirstRunTest do
  @moduledoc """
  SF-120: ARW1, the Control Plane first visit and tour, as the ADR 0018 experience
  `control_plane_web_tour`, over HTTP (in-process endpoint, PostgreSQL in the SQL
  sandbox). Offered to an active operator only; the first outcome is final and the
  same on every device; recording it grants, checks and changes nothing.
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.{Accounts, Repo}
  alias SimpleFit.Operators.{Grant, Operator}
  alias SimpleFitWeb.ApiSpec

  @experience "control_plane_web_tour"

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    :ok
  end

  defp token!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    {credentials.access_token, credentials.session}
  end

  defp call(method, path, token, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    case method do
      :get ->
        get(conn, path)

      :put ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put(path, Jason.encode!(body))
    end
  end

  defp state(token) do
    body = call(:get, "/api/v1/me/first-run", token) |> json_response(200)
    assert_schema(body, "FirstRunResponse", ApiSpec.spec())
    Enum.find(body["experiences"], &(&1["experience"] == @experience))
  end

  defp record(token, outcome),
    do: call(:put, "/api/v1/me/first-run/#{@experience}", token, %{"outcome" => outcome})

  test "an account that isn't an operator: unavailable, and nothing can be recorded" do
    {token, _} = token!(registered!("not-operator"))
    assert %{"status" => "unavailable"} = state(token)
    assert record(token, "completed") |> json_response(409)
  end

  test "SF-157: a pending operator (keys not registered) is offered it: it reads the Control Plane at session assurance" do
    user = registered!("pending-operator")
    {token, _} = token!(user)
    _ = bootstrap!(user)
    assert %{"status" => "pending"} = state(token)

    assert %{"experience" => %{"status" => "dismissed"}} =
             record(token, "dismissed") |> json_response(200)
  end

  test "an active operator: pending, then the first outcome is final and grants nothing" do
    user = registered!("active-operator")
    {token, session} = token!(user)
    operator = bootstrap!(user, ["audit.read"])
    _ = enroll!(user, session)
    grants_before = Repo.aggregate(Grant, :count)

    assert %{"status" => "pending", "recorded_at" => nil} = state(token)

    assert %{"experience" => %{"status" => "completed"}} =
             body = record(token, "completed") |> json_response(200)

    assert_schema(body, "FirstRunExperienceResponse", ApiSpec.spec())

    # Recording again, either outcome, keeps the first (another tab or device).
    assert %{"experience" => %{"status" => "completed"}} =
             record(token, "dismissed") |> json_response(200)

    # Another session (another device) sees the same.
    {other_token, _} = token!(user)
    assert %{"status" => "completed"} = state(other_token)

    # Nothing about the operator changed.
    assert Repo.aggregate(Grant, :count) == grants_before
    assert %Operator{status: :active} = Repo.reload!(operator)

    # Another account's experience is its own.
    {stranger, _} = token!(registered!("stranger"))
    assert %{"status" => "unavailable"} = state(stranger)
  end

  test "a forged user or extra field is refused; only the outcome is accepted" do
    user = registered!("forging-operator")
    {token, session} = token!(user)
    _ = bootstrap!(user)
    _ = enroll!(user, session)

    assert call(:put, "/api/v1/me/first-run/#{@experience}", token, %{"outcome" => "maybe"})
           |> json_response(422)

    assert %{"status" => "pending"} = state(token)
  end
end
