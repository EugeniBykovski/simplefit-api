defmodule SimpleFit.Email.ResendTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SimpleFit.Email.{Message, Resend}

  @config [
    api_key: "re_test_secret_key",
    from: "SimpleFit <no-reply@simplefit.test>",
    req_options: [plug: {Req.Test, SimpleFit.Email.Resend}]
  ]

  setup do
    {:ok, message} =
      Message.new(
        to: "fighter@example.com",
        subject: "Welcome",
        text: "Hello",
        html: "<p>Hello</p>"
      )

    %{message: message}
  end

  test "posts the message to Resend with bearer auth and idempotency key", %{message: message} do
    Req.Test.expect(Resend, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/emails"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer re_test_secret_key"]
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["email-job-42"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "from" => "SimpleFit <no-reply@simplefit.test>",
               "to" => ["fighter@example.com"],
               "subject" => "Welcome",
               "text" => "Hello",
               "html" => "<p>Hello</p>"
             }

      Req.Test.json(conn, %{"id" => "4ef9a417-02e9-4d39-ad75-9611e0fcc33c"})
    end)

    assert Resend.deliver(message, @config, idempotency_key: "email-job-42") ==
             {:ok, %{id: "4ef9a417-02e9-4d39-ad75-9611e0fcc33c"}}
  end

  test "a message sender overrides the configured default", %{message: message} do
    Req.Test.expect(Resend, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["from"] == "Coach <coach@simplefit.test>"
      Req.Test.json(conn, %{"id" => "1"})
    end)

    assert {:ok, _} =
             Resend.deliver(%{message | from: "Coach <coach@simplefit.test>"}, @config, [])
  end

  test "normalizes provider errors without leaking response bodies", %{message: message} do
    for {status, reason} <- [
          {401, :unauthorized},
          {403, :unauthorized},
          {422, :invalid_request},
          {429, :rate_limited},
          {500, :unavailable}
        ] do
      Req.Test.expect(Resend, fn conn ->
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"name" => "error", "message" => "provider-internal-detail"})
      end)

      log =
        capture_log(fn -> assert Resend.deliver(message, @config, []) == {:error, reason} end)

      refute log =~ "provider-internal-detail"
      refute log =~ "re_test_secret_key"
    end
  end

  test "normalizes timeouts and connection failures", %{message: message} do
    Req.Test.expect(Resend, &Req.Test.transport_error(&1, :timeout))
    capture_log(fn -> assert Resend.deliver(message, @config, []) == {:error, :timeout} end)

    Req.Test.expect(Resend, &Req.Test.transport_error(&1, :econnrefused))
    capture_log(fn -> assert Resend.deliver(message, @config, []) == {:error, :unavailable} end)
  end

  test "treats an unexpected success body as unavailable", %{message: message} do
    Req.Test.expect(Resend, &Req.Test.json(&1, %{"unexpected" => true}))
    capture_log(fn -> assert Resend.deliver(message, @config, []) == {:error, :unavailable} end)
  end

  test "fails closed without calling Resend when not configured", %{message: message} do
    # No Req.Test expectation: any HTTP call would fail the test.
    for config <- [
          Keyword.delete(@config, :api_key),
          Keyword.put(@config, :api_key, ""),
          Keyword.delete(@config, :from)
        ] do
      log =
        capture_log(fn ->
          assert Resend.deliver(message, config, []) == {:error, :configuration_error}
        end)

      assert log =~ "email is not configured"
    end
  end
end
