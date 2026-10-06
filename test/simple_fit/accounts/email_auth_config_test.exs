defmodule SimpleFit.Accounts.EmailAuthConfigTest do
  # Not async: changes the email authentication configuration.
  use ExUnit.Case, async: false

  alias SimpleFit.Accounts.EmailAuth

  test "the production policy: 10-minute challenges, 5 attempts, 60 s resend" do
    assert %{challenge_ttl: 600, max_failed_attempts: 5, resend_cooldown: 60} =
             EmailAuth.config!()
  end

  test "an inconsistent policy or missing key material fails" do
    original = Application.get_env(:simple_fit, EmailAuth)
    on_exit(fn -> Application.put_env(:simple_fit, EmailAuth, original) end)

    for change <- [
          [challenge_ttl: 90],
          [max_failed_attempts: 0],
          [resend_cooldown: nil],
          [web_app_url: nil],
          [secret_key_base: "short"]
        ] do
      Application.put_env(:simple_fit, EmailAuth, Keyword.merge(original, change))
      assert_raise ArgumentError, fn -> EmailAuth.config!() end
    end
  end

  test "WEB_APP_URL must be an origin; production requires https" do
    assert EmailAuth.parse_web_app_url!("https://app.example.com") == "https://app.example.com"
    assert EmailAuth.parse_web_app_url!("https://app.example.com/") == "https://app.example.com"
    assert EmailAuth.parse_web_app_url!("http://localhost:3000") == "http://localhost:3000"

    for bad <- [
          "app.example.com",
          "https://app.example.com/path",
          "https://app.example.com?x=1",
          "https://app.example.com#x",
          "https://user@app.example.com",
          "ftp://app.example.com"
        ] do
      assert_raise ArgumentError, fn -> EmailAuth.parse_web_app_url!(bad) end
    end

    assert_raise ArgumentError, fn ->
      EmailAuth.parse_web_app_url!("http://app.example.com", require_https: true)
    end
  end
end
