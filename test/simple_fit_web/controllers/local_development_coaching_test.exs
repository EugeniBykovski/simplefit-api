defmodule SimpleFitWeb.LocalDevelopmentCoachingTest do
  @moduledoc """
  LOCAL DEVELOPMENT coaching mode over HTTP (SF-81, ADR 0025), on the real
  endpoints and PostgreSQL with no legal configuration: the `legal_mode`
  clients read, the invitation flow without data rules or a disclosure text,
  and the approved regime unchanged when the mode is off. Responses are
  checked against the OpenAPI schemas.
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaching.LocalDevelopment
  alias SimpleFitWeb.ApiSpec

  @marker "local-development-no-legal-text"

  setup do
    reset_rate_limits()
    on_exit(fn -> LocalDevelopment.put_active_for_test(false) end)
    :ok
  end

  defp api(%User{} = user, method, path, body \\ nil) do
    {:ok, credentials} = Accounts.create_session(user)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> credentials.access_token)
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, body && Jason.encode!(body))
  end

  defp anonymous(method, path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp body(conn, status, schema) do
    body = json_response(conn, status)
    assert_schema(body, schema, ApiSpec.spec())
    body
  end

  defp address, do: "dev-http-#{System.unique_integer([:positive])}@example.com"

  test "mode on: invite at once, preview without a text, accept explicitly, roster" do
    configure_sharing(enabled: false, disclosures: %{}, current: nil, data_rules: nil)
    LocalDevelopment.put_active_for_test(true)
    coach = coach_user!("Dev Coach")

    rules = api(coach, :get, "/api/v1/me/coach/data-rules") |> body(200, "CoachDataRulesResponse")

    assert rules["data_rules"] == %{
             "legal_mode" => "local_development",
             "document_version" => nil,
             "acknowledged_at" => nil,
             "document" => nil
           }

    to = address()

    assert %{"invitation" => %{"status" => "pending"}} =
             api(coach, :post, "/api/v1/me/coach/invitations", %{email: to})
             |> body(201, "CoachInvitationResponse")

    token = last_token_to(to)

    shown =
      anonymous(:post, "/api/v1/coach-invitations/preview", %{token: token})
      |> body(200, "CoachInvitationPreview")

    assert shown["legal_mode"] == "local_development"
    assert shown["document"] == nil
    assert shown["disclosure"]["version"] == @marker

    fighter = email_fighter!(to)

    accepted =
      api(fighter, :post, "/api/v1/me/coach-invitations/accept", %{
        token: token,
        disclosure_version: shown["disclosure"]["version"]
      })
      |> body(200, "CoachInvitationAcceptResponse")

    assert accepted["outcome"] == "created"

    roster = api(coach, :get, "/api/v1/me/coach/fighters") |> json_response(200)
    assert [%{"relationship_id" => id, "fighter" => fighter_view}] = roster["relationships"]
    assert id == accepted["relationship_id"]
    assert fighter_view["display_name"]
  end

  test "mode off: the approved regime is unchanged" do
    configure_sharing()
    coach = inviting_coach!()

    rules = api(coach, :get, "/api/v1/me/coach/data-rules") |> body(200, "CoachDataRulesResponse")
    assert rules["data_rules"]["legal_mode"] == "approved"
    assert rules["data_rules"]["document_version"] == data_rules_version()

    to = address()
    {_invitation, token} = invite!(coach, to)

    shown =
      anonymous(:post, "/api/v1/coach-invitations/preview", %{token: token})
      |> body(200, "CoachInvitationPreview")

    assert shown["legal_mode"] == "approved"
    assert shown["document"]["version"] == version()

    fighter = email_fighter!(to)

    # Without the language of the text shown: refused, nothing accepted.
    assert %{"error" => %{"code" => "validation_error"}} =
             api(fighter, :post, "/api/v1/me/coach-invitations/accept", %{
               token: token,
               disclosure_version: version()
             })
             |> json_response(422)

    # The marker is not a disclosure version here.
    assert api(fighter, :post, "/api/v1/me/coach-invitations/accept", %{
             token: token,
             disclosure_version: @marker,
             document_language: "en"
           }).status == 409
  end

  test "mode off and nothing configured: every coaching surface is unavailable" do
    configure_sharing(enabled: false, disclosures: %{}, current: nil, data_rules: nil)
    coach = coach_user!()
    assert api(coach, :get, "/api/v1/me/coach/data-rules").status == 404
    assert api(coach, :get, "/api/v1/me/coach/fighters").status == 404
    assert api(coach, :post, "/api/v1/me/coach/invitations", %{email: address()}).status == 404
  end
end
