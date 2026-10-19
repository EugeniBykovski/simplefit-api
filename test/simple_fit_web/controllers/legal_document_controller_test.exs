defmodule SimpleFitWeb.LegalDocumentControllerTest do
  @moduledoc """
  SF-72 over HTTP: the public legal document endpoints, the coach data
  rules with their text and language, the fighter's acceptance errors
  (language, 18+), OpenAPI schemas, and no legal text, token or date of
  birth in any log.
  """

  # Not async: the registry and the sharing configuration are global.
  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import OpenApiSpex.TestAssertions
  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers
  import SimpleFit.LegalHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Coaching.Activation
  alias SimpleFitWeb.ApiSpec

  setup do
    configure_sharing()
    reset_rate_limits()
    :ok
  end

  defp token(user) do
    {:ok, credentials} = Accounts.create_session(user)
    credentials.access_token
  end

  defp authed(user), do: build_conn() |> put_req_header("authorization", "Bearer " <> token(user))

  defp json_post(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp ok!(conn, schema) do
    body = json_response(conn, 200)
    assert_schema(body, schema, ApiSpec.spec())
    body
  end

  defp error!(conn, status, code) do
    body = json_response(conn, status)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    assert body["error"]["code"] == code
    body["error"]
  end

  describe "public documents" do
    test "the current version in an approved language, without sign-in" do
      doc =
        ok!(
          get(build_conn(), "/api/v1/legal-documents/fighter-coach-disclosure?language=pl"),
          "LegalDocumentResponse"
        )[
          "document"
        ]

      assert doc["version"] == version()
      assert doc["status"] == "published"
      assert doc["language"] == "pl" and doc["requested_language"] == "pl"
      assert doc["full"] =~ "TEST FIXTURE"
      assert doc["content_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "an unapproved language returns metadata only, never another language" do
      doc =
        ok!(
          get(build_conn(), "/api/v1/legal-documents/coach-data-rules?language=fr"),
          "LegalDocumentResponse"
        )[
          "document"
        ]

      assert doc["requested_language"] == "fr" and doc["language"] == nil
      assert doc["full"] == nil and doc["summary"] == nil and doc["title"] == nil
      assert doc["available_languages"] == ["en", "pl"]
    end

    test "archives, drafts, withdrawn and unknown versions" do
      build_registry!([
        %{
          document_id: "fighter-coach-disclosure",
          version: version(),
          scope: "basic_profile",
          status: "superseded"
        },
        %{
          document_id: "fighter-coach-disclosure",
          version: "fighter-coach-disclosure-test-2",
          scope: "basic_profile"
        },
        %{
          document_id: "fighter-coach-disclosure",
          version: "fighter-coach-disclosure-test-3",
          scope: "basic_profile",
          status: "draft"
        },
        %{document_id: "coach-data-rules", version: data_rules_version(), status: "withdrawn"}
      ])

      base = "/api/v1/legal-documents"

      assert ok!(
               get(
                 build_conn(),
                 "#{base}/fighter-coach-disclosure/versions/#{version()}?language=en"
               ),
               "LegalDocumentResponse"
             )[
               "document"
             ]["status"] == "superseded"

      assert ok!(
               get(build_conn(), "#{base}/fighter-coach-disclosure?language=en"),
               "LegalDocumentResponse"
             )[
               "document"
             ]["version"] == "fighter-coach-disclosure-test-2"

      for path <- [
            "#{base}/fighter-coach-disclosure/versions/fighter-coach-disclosure-test-3",
            "#{base}/coach-data-rules",
            "#{base}/coach-data-rules/versions/#{data_rules_version()}",
            "#{base}/fighter-coach-disclosure/versions/unknown",
            "#{base}/privacy-notice",
            "#{base}/%27%20OR%201%3D1"
          ] do
        error!(get(build_conn(), path), 404, "not_found")
      end
    end

    test "with the production registry nothing is published: 404, never placeholder text" do
      use_production_registry!()

      for id <- ["fighter-coach-disclosure", "coach-data-rules"] do
        error!(get(build_conn(), "/api/v1/legal-documents/#{id}?language=en"), 404, "not_found")
      end
    end
  end

  describe "coach data rules" do
    test "the text in the requested language, acknowledgement with that language" do
      coach = coach_user!()

      rules =
        ok!(
          authed(coach) |> get("/api/v1/me/coach/data-rules?language=pl"),
          "CoachDataRulesResponse"
        )[
          "data_rules"
        ]

      assert rules["document"]["language"] == "pl"
      assert rules["document"]["checkbox"] =~ "TEST FIXTURE"
      assert rules["acknowledged_at"] == nil

      body =
        authed(coach)
        |> json_post("/api/v1/me/coach/data-rules/acknowledge", %{
          document_version: rules["document_version"],
          document_language: "de"
        })
        |> error!(409, "conflict")

      assert body["details"] == %{"document_language" => "unavailable"}

      acknowledged =
        authed(coach)
        |> json_post("/api/v1/me/coach/data-rules/acknowledge", %{
          document_version: rules["document_version"],
          document_language: "pl"
        })
        |> ok!("CoachDataRulesResponse")

      assert acknowledged["data_rules"]["acknowledged_at"]
      assert acknowledged["data_rules"]["document"]["language"] == "pl"
    end

    test "unavailable without published documents" do
      coach = coach_user!()
      use_production_registry!()
      error!(authed(coach) |> get("/api/v1/me/coach/data-rules?language=en"), 404, "not_found")
    end
  end

  describe "fighter acceptance errors" do
    test "too young: 422 coaching_age too_young; unapproved language: 409; nothing logged" do
      coach = inviting_coach!()
      email = "minor-#{System.unique_integer([:positive])}@example.com"
      {:ok, minor} = Accounts.register_user(:email, email)
      born = Activation.eligibility_date() |> Date.shift(year: -17)

      {:ok, _} =
        Accounts.update_account_registration(minor, %{
          "full_name" => "Minor Person",
          "date_of_birth" => Date.to_iso8601(born),
          "accept_terms" => true,
          "accept_privacy" => true
        })

      {:ok, _} = Accounts.complete_account_registration(minor)

      {:ok, _} =
        SimpleFit.Fighters.update_profile(minor, %{
          "display_name" => "Minor F.",
          "username" => "minor_#{System.unique_integer([:positive])}",
          "country_code" => "PL",
          "city" => "Warsaw",
          "experience_level" => "amateur",
          "stance" => "orthodox"
        })

      {:ok, _} = SimpleFit.Fighters.complete_onboarding(minor)
      {_invitation, invite_token} = invite!(coach, email)

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :debug], fn ->
          preview =
            build_conn()
            |> json_post("/api/v1/coach-invitations/preview", %{
              token: invite_token,
              language: "en"
            })
            |> ok!("CoachInvitationPreview")

          assert preview["document"]["summary"] =~ "TEST FIXTURE"

          details =
            authed(minor)
            |> json_post("/api/v1/me/coach-invitations/accept", %{
              token: invite_token,
              disclosure_version: version(),
              document_language: "en"
            })
            |> error!(422, "validation_error")
            |> Map.fetch!("details")

          assert details["field_codes"] == %{"coaching_age" => ["too_young"]}
          refute inspect(details) =~ Date.to_iso8601(born)

          body =
            authed(minor)
            |> json_post("/api/v1/me/coach-invitations/accept", %{
              token: invite_token,
              disclosure_version: version(),
              document_language: "uk"
            })
            |> error!(409, "conflict")

          assert body["details"] == %{"document_language" => "unavailable"}
        end)

      refute log =~ invite_token
      refute log =~ "TEST FIXTURE"
      refute log =~ Date.to_iso8601(born)
      refute log =~ email
    end
  end
end
