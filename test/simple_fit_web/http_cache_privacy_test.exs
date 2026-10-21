defmodule SimpleFitWeb.HttpCachePrivacyTest do
  @moduledoc """
  No authenticated answer may be kept by an HTTP cache (SF-70, ADR 0010):
  every route behind `:authenticated` is `Cache-Control: no-store`, whether
  it answers, refuses the token or fails, and no controller weakens it.
  """

  use SimpleFitWeb.ConnCase, async: true

  alias SimpleFit.Accounts

  defp authenticated_routes do
    Enum.filter(SimpleFitWeb.Router.__routes__(), fn route ->
      method = route.verb |> Atom.to_string() |> String.upcase()
      info = Phoenix.Router.route_info(SimpleFitWeb.Router, method, concrete(route.path), "")
      :authenticated in info.pipe_through
    end)
  end

  # Path params get a well-formed id, so routing matches; the answer may be 404.
  defp concrete(path) do
    String.replace(path, ~r/:[a-z_]+/, "00000000-0000-4000-8000-000000000000")
  end

  test "the authenticated scopes are covered" do
    assert length(authenticated_routes()) > 20
    assert Enum.any?(authenticated_routes(), &(&1.path == "/api/me"))
  end

  test "every authenticated route is no-store, even when the token is refused" do
    for route <- authenticated_routes() do
      method = route.verb |> Atom.to_string() |> String.upcase()

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, concrete(route.path), "{}")

      assert conn.status == 401, "#{method} #{route.path} answered #{conn.status}"

      assert get_resp_header(conn, "cache-control") == ["no-store"],
             "#{method} #{route.path} is cacheable"
    end
  end

  test "answers with personal data stay no-store" do
    {:ok, user} = Accounts.register_user(:email, "cache-privacy@example.com")
    {:ok, credentials} = Accounts.create_session(user)

    for path <- [~p"/api/me", ~p"/api/v1/me/entry"] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> credentials.access_token)
        |> get(path)

      assert conn.status == 200, "#{path} answered #{conn.status}"
      assert get_resp_header(conn, "cache-control") == ["no-store"], "#{path} is cacheable"
    end
  end
end
