defmodule SimpleFitWeb.SignInMethodControllerTest do
  @moduledoc """
  The viewer's sign-in methods over HTTP on the real endpoint and PostgreSQL
  (SF-161): the contract (OpenAPI schema, no-store, normalized errors), the
  methods of each provider, and isolation between accounts.
  """

  # Not async: provider key caches and rate limits are shared.
  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.{Accounts, AppleTokens, GoogleTokens}
  alias SimpleFitWeb.ApiSpec

  @list "/api/v1/me/sign-in-methods"

  setup do
    reset_rate_limits()
    GoogleTokens.reset()
    GoogleTokens.stub_jwks(self())
    AppleTokens.reset()
    AppleTokens.stub_jwks(self())
    :ok
  end

  defp address, do: "methods-#{System.unique_integer([:positive])}@example.com"

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp list!(token) do
    conn = token |> authed() |> get(@list)
    body = json_response(conn, 200)
    assert_schema(body, "SignInMethodList", ApiSpec.spec())
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body["sign_in_methods"]
  end

  defp token_for(user) do
    {:ok, %{access_token: token}} = Accounts.create_session(user)
    token
  end

  # The provider reports `claim` as a verified email: it must never be listed.
  defp google_sign_in(subject, claim) do
    token = GoogleTokens.valid_token(subject, %{"email" => claim, "email_verified" => true})
    build_conn() |> post_json("/api/auth/google", %{id_token: token}) |> json_response(200)
  end

  defp apple_sign_in(subject, claim) do
    credential = AppleTokens.credential(subject, %{"email" => claim, "email_verified" => "true"})
    build_conn() |> post_json("/api/auth/apple", credential) |> json_response(200)
  end

  test "requires a valid access token" do
    for conn <- [build_conn() |> get(@list), authed("sfa_not-a-token") |> get(@list)] do
      body = json_response(conn, 401)
      assert_schema(body, "ErrorResponse", ApiSpec.spec())
      assert body["error"]["code"] == "unauthorized"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end
  end

  test "an email account lists its proven address" do
    {:ok, user} = Accounts.register_user(:email, email = address())

    assert [%{"provider" => "email", "email" => ^email, "linked_at" => linked_at}] =
             list!(token_for(user))

    assert {:ok, _at, 0} = DateTime.from_iso8601(linked_at)
  end

  test "a Google or Apple account lists the provider, never its account id or reported email" do
    claim = address()
    google = google_sign_in(subject = "google-sub-#{System.unique_integer([:positive])}", claim)

    apple =
      apple_sign_in(apple_subject = "apple.sub.#{System.unique_integer([:positive])}", claim)

    assert [%{"provider" => "google", "email" => nil}] = list!(google["access_token"])
    assert [%{"provider" => "apple", "email" => nil}] = list!(apple["access_token"])

    for body <- [google, apple] do
      raw = body["access_token"] |> authed() |> get(@list) |> response(200)
      refute raw =~ subject
      refute raw =~ apple_subject
      refute raw =~ claim
    end
  end

  test "a linked email appears beside the provider that signed in" do
    google = google_sign_in("google-sub-#{System.unique_integer([:positive])}", address())
    token = google["access_token"]
    linked = address()

    conn =
      token
      |> authed()
      |> post_json("/api/v1/me/email-identities/link-challenge", %{email: linked})

    assert json_response(conn, 202)
    code = code_from(last_email_to(linked))

    conn =
      token
      |> authed()
      |> post_json("/api/v1/me/email-identities/confirm-link", %{email: linked, code: code})

    assert json_response(conn, 200)

    # Added within the same second: ordered by provider then.
    assert [%{"provider" => "email", "email" => ^linked}, %{"provider" => "google"}] =
             list!(token)
  end

  test "each account sees only its own methods" do
    {:ok, a} = Accounts.register_user(:email, email_a = address())
    {:ok, b} = Accounts.register_user(:email, email_b = address())

    assert [%{"email" => ^email_a}] = list!(token_for(a))
    assert [%{"email" => ^email_b}] = list!(token_for(b))
  end
end
