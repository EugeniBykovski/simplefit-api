defmodule SimpleFitWeb.ApiDocsControllerTest do
  # Not async: toggles the global :api_docs application env.
  use SimpleFitWeb.ConnCase, async: false

  alias SimpleFitWeb.ApiSpec

  setup do
    original = Application.get_env(:simple_fit, :api_docs)
    on_exit(fn -> Application.put_env(:simple_fit, :api_docs, original) end)
    :ok
  end

  defp set_docs_enabled(enabled),
    do: Application.put_env(:simple_fit, :api_docs, enabled: enabled)

  describe "when API docs are enabled" do
    setup do: set_docs_enabled(true)

    test "GET /api/openapi serves the same contract as the committed artifact", %{conn: conn} do
      conn = get(conn, ~p"/api/openapi")

      assert json_response(conn, 200) ==
               ApiSpec.artifact_path() |> File.read!() |> Jason.decode!()
    end

    test "GET /api/docs serves the Scalar reference with a dedicated CSP", %{conn: conn} do
      conn = get(conn, ~p"/api/docs")

      body = html_response(conn, 200)
      assert body =~ "Scalar.createApiReference"
      assert body =~ ~s("url":"/api/openapi")
      assert body =~ ~s(integrity="sha384-)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src https://cdn.jsdelivr.net/npm/@scalar/api-reference@"
      assert csp =~ "connect-src 'self'"
      assert csp =~ "frame-ancestors 'none'"
      refute csp =~ "unsafe-eval"
    end
  end

  describe "when API docs are disabled" do
    setup do: set_docs_enabled(false)

    test "GET /api/openapi is indistinguishable from an unknown route", %{conn: conn} do
      conn = get(conn, ~p"/api/openapi")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "GET /api/docs is indistinguishable from an unknown route", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get(~p"/api/docs")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "the health endpoint is unaffected", %{conn: conn} do
      assert conn |> get(~p"/api/health") |> json_response(200)
    end
  end
end
