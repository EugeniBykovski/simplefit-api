defmodule SimpleFitWeb.AppleAuthPrivacyTest do
  @moduledoc """
  Apple identity tokens, nonces and subjects never leave the request
  (ADR 0014), and a missing configuration fails closed and is diagnosable.
  """

  use SimpleFitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import SimpleFit.AppleTokens

  require Record

  alias SimpleFit.Accounts
  alias SimpleFit.Identity.Apple

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  @events for e <- [:verified, :rejected, :unavailable, :rate_limited, :keys_unavailable],
              do: [:simple_fit, :auth, :apple, e]

  @subject "000999.secretsubject.1234"
  @email "hidden.person@privaterelay.appleid.com"

  setup do
    reset()
    stub_jwks(self())
    :ok
  end

  defp post_apple(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/apple", Jason.encode!(body))
  end

  defp exercise do
    good = credential(@subject, %{"email" => @email})
    raw = raw_nonce()
    bad = %{id_token: token(claims(@subject, raw, %{"aud" => "com.other"})), nonce: raw}
    mismatch = %{good | nonce: raw_nonce()}

    conns = for body <- [good, good, bad, mismatch], do: post_apple(body)

    [_header, payload, signature] = String.split(good.id_token, ".")

    secrets = [
      good.id_token,
      payload,
      signature,
      good.nonce,
      hashed(good.nonce),
      bad.nonce,
      mismatch.nonce,
      @subject,
      @email
    ]

    %{conns: conns, secrets: secrets}
  end

  test "no token, nonce, subject or email reaches the logs, even at debug level" do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {%{secrets: secrets}, log} = with_log([level: :debug], fn -> exercise() end)
    assert log =~ "request completed"

    for secret <- secrets, do: refute(log =~ secret)
  end

  test "telemetry carries bounded reasons only; no Sentry report; no secret in error bodies" do
    ref = :telemetry_test.attach_event_handlers(self(), @events)
    Sentry.Test.start_collecting_sentry_reports()

    %{conns: conns, secrets: secrets} = exercise()

    events = collect(ref, [])
    assert Enum.any?(events, &match?({[_, _, _, :rejected], %{reason: :audience}}, &1))
    assert Enum.any?(events, &match?({[_, _, _, :rejected], %{reason: :nonce}}, &1))

    for {_event, metadata} <- events, secret <- secrets do
      refute inspect(metadata, limit: :infinity) =~ secret
    end

    for conn <- conns, conn.status >= 400, secret <- secrets do
      refute conn.resp_body =~ secret
    end

    assert Sentry.Test.pop_sentry_reports() == []
  end

  test "traces keep no token, nonce or subject" do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    %{secrets: secrets} = exercise()

    for span_record <- collect_spans([]), secret <- secrets do
      refute inspect(span(span_record, :attributes), limit: :infinity) =~ secret
    end
  end

  test "id_token and nonce are filtered parameters; the identity subject is redacted" do
    assert Phoenix.Logger.filter_values(%{"id_token" => "eyJ.secret.sig", "nonce" => "raw"}) ==
             %{"id_token" => "[FILTERED]", "nonce" => "[FILTERED]"}

    %{id_token: token, nonce: nonce} = credential(@subject)
    {:ok, _} = Accounts.authenticate_with_apple(token, nonce, "203.0.113.9")
    {:ok, identity} = Accounts.get_identity(:apple, @subject)
    refute inspect(identity) =~ @subject
  end

  test "missing configuration fails closed with service_unavailable and logs only the reason" do
    original = Application.get_env(:simple_fit, Apple)
    Application.put_env(:simple_fit, Apple, Keyword.put(original, :client_ids, []))
    on_exit(fn -> Application.put_env(:simple_fit, Apple, original) end)

    body = credential(@subject)
    {conn, log} = with_log([level: :warning], fn -> post_apple(body) end)

    assert %{"error" => %{"code" => "service_unavailable", "details" => %{}}} =
             json_response(conn, 503)

    refute conn.resp_body =~ "not_configured"
    refute conn.resp_body =~ "APPLE_SIGN_IN_CLIENT_IDS"
    assert log =~ "apple sign-in unavailable"
    assert log =~ "reason=not_configured"

    for secret <- [body.id_token, body.nonce, @subject, "com.simplefit.test"] do
      refute log =~ secret
    end
  end

  defp collect(ref, acc) do
    receive do
      {event, ^ref, _measurements, metadata} -> collect(ref, [{event, metadata} | acc])
    after
      100 -> acc
    end
  end

  defp collect_spans(acc) do
    receive do
      {:span, span_record} -> collect_spans([span_record | acc])
    after
      200 -> acc
    end
  end
end
