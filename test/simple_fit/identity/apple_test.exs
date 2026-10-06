defmodule SimpleFit.Identity.AppleTest do
  # Not async: the signing-key cache is one supervised process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import SimpleFit.AppleTokens

  alias SimpleFit.Identity
  alias SimpleFit.Identity.Apple

  setup do
    reset()
    stub_jwks(self())
    :ok
  end

  defp verify(credential), do: Identity.verify(:apple, credential)

  defp with_claims(sub, overrides) do
    raw = raw_nonce()
    %{id_token: token(claims(sub, raw, overrides)), nonce: raw}
  end

  describe "valid tokens" do
    test "native (bundle id) and web (Services ID) audiences resolve to the subject only" do
      for aud <- [native_client(), web_client()] do
        assert {:ok, %{provider: :apple, subject: "001234.abc.0987"} = result} =
                 verify(with_claims("001234.abc.0987", %{"aud" => aud}))

        assert Map.keys(result) == [:provider, :subject]
      end
    end

    test "ignored claims do not matter (no email, private relay, missing name)" do
      raw = raw_nonce()

      minimal =
        claims("s1", raw)
        |> Map.drop(["email", "email_verified", "is_private_email", "real_user_status"])

      assert {:ok, %{subject: "s1"}} = verify(%{id_token: token(minimal), nonce: raw})
    end

    test "small clock skew is tolerated" do
      now = System.os_time(:second)
      assert {:ok, _} = verify(with_claims("1", %{"iat" => now + 20}))
      assert {:ok, _} = verify(with_claims("1", %{"exp" => now - 20}))
    end
  end

  describe "invalid credentials are rejected with a bounded reason" do
    test "structure and header" do
      raw = raw_nonce()
      assert {:error, {:rejected, :malformed}} = verify(%{id_token: "not.a.jwt", nonce: raw})
      assert {:error, {:rejected, :malformed}} = verify(%{id_token: "garbage", nonce: raw})
      assert {:error, {:rejected, :malformed}} = verify(%{id_token: 1, nonce: raw})
      assert {:error, {:rejected, :malformed}} = verify(%{id_token: "x"})
      assert {:error, {:rejected, :malformed}} = verify("token")

      %{id_token: good} = credential("1")
      [_header, payload, _sig] = String.split(good, ".")
      encode = &Base.url_encode64(&1, padding: false)

      assert {:error, {:rejected, :malformed}} =
               verify(%{id_token: "#{encode.(~s({"alg":"RS256"}))}.#{payload}.x", nonce: raw})

      assert {:error, {:rejected, :malformed}} =
               verify(%{
                 id_token: "#{encode.(~s({"alg":"RS256","kid":""}))}.#{payload}.x",
                 nonce: raw
               })

      assert {:error, {:rejected, :unsupported_algorithm}} =
               verify(%{
                 id_token: "#{encode.(~s({"alg":"none","kid":"apple-key-1"}))}.#{payload}.",
                 nonce: raw
               })

      {_, hs256} =
        JOSE.JWK.from_oct("secret")
        |> JOSE.JWT.sign(%{"alg" => "HS256", "kid" => "apple-key-1"}, claims("1", raw))
        |> JOSE.JWS.compact()

      assert {:error, {:rejected, :unsupported_algorithm}} =
               verify(%{id_token: hs256, nonce: raw})
    end

    test "signature and keys" do
      raw = raw_nonce()

      forged = token(claims("1", raw), key: JOSE.JWK.generate_key({:rsa, 2048}))
      assert {:error, {:rejected, :bad_signature}} = verify(%{id_token: forged, nonce: raw})

      unknown = token(claims("1", raw), kid: "not-published")
      assert {:error, {:rejected, :unknown_key}} = verify(%{id_token: unknown, nonce: raw})
    end

    test "issuer and audience" do
      for iss <- ["appleid.apple.com", "https://accounts.google.com", "https://evil.example"] do
        assert {:error, {:rejected, :issuer}} = verify(with_claims("1", %{"iss" => iss}))
      end

      assert {:error, {:rejected, :audience}} =
               verify(with_claims("1", %{"aud" => "com.other.app"}))

      assert {:error, {:rejected, :audience}} =
               verify(with_claims("1", %{"aud" => [native_client()]}))

      assert {:error, {:rejected, :audience}} = verify(with_claims("1", %{"aud" => nil}))
    end

    test "time" do
      now = System.os_time(:second)
      assert {:error, {:rejected, :expired}} = verify(with_claims("1", %{"exp" => now - 120}))
      assert {:error, {:rejected, :expired}} = verify(with_claims("1", %{"exp" => "soon"}))

      assert {:error, {:rejected, :not_yet_valid}} =
               verify(with_claims("1", %{"iat" => now + 600}))

      raw = raw_nonce()
      no_iat = claims("1", raw) |> Map.delete("iat") |> token()
      assert {:error, {:rejected, :not_yet_valid}} = verify(%{id_token: no_iat, nonce: raw})
    end

    test "subject" do
      for sub <- [nil, "", 42, "has space", String.duplicate("1", 256), "naïve"] do
        assert {:error, {:rejected, :subject}} = verify(with_claims("x", %{"sub" => sub})),
               inspect(sub)
      end

      assert {:ok, _} = verify(with_claims(String.duplicate("1", 255), %{}))
    end

    test "nonce" do
      raw = raw_nonce()
      %{id_token: token} = %{id_token: token(claims("1", raw))}

      assert {:ok, _} = verify(%{id_token: token, nonce: raw})
      # Another raw nonce, the hash itself, or a token without a nonce claim.
      assert {:error, {:rejected, :nonce}} = verify(%{id_token: token, nonce: raw_nonce()})
      assert {:error, {:rejected, :nonce}} = verify(%{id_token: token, nonce: hashed(raw)})

      assert {:error, {:rejected, :nonce}} =
               verify(%{id_token: token(Map.delete(claims("1", raw), "nonce")), nonce: raw})

      # The raw value sent to Apple instead of its hash.
      assert {:error, {:rejected, :nonce}} =
               verify(%{id_token: token(claims("1", raw, %{"nonce" => raw})), nonce: raw})

      assert {:error, {:rejected, :nonce}} =
               verify(%{
                 id_token: token(claims("1", raw, %{"nonce" => String.upcase(hashed(raw))})),
                 nonce: raw
               })
    end
  end

  describe "signing keys (Apple sends Cache-Control: no-store)" do
    test "are cached with the default lifetime instead of fetched per request" do
      assert {:ok, _} = verify(credential("1"))
      assert {:ok, _} = verify(credential("2"))
      assert_received :apple_jwks_fetched
      refute_received :apple_jwks_fetched
    end

    test "an unknown kid triggers at most one refresh per minute" do
      raw = raw_nonce()

      for n <- 1..5 do
        assert {:error, {:rejected, :unknown_key}} =
                 verify(%{id_token: token(claims("1", raw), kid: "random-#{n}"), nonce: raw})
      end

      assert_received :apple_jwks_fetched
      refute_received :apple_jwks_fetched
    end

    test "key rotation: a newly published kid is picked up" do
      stub_jwks(self(), kids: ["apple-key-1", "apple-key-2"])
      raw = raw_nonce()

      assert {:ok, _} =
               verify(%{id_token: token(claims("1", raw), kid: "apple-key-2"), nonce: raw})
    end

    test "Apple outage: cached keys keep working; without keys, fail closed" do
      assert {:ok, _} = verify(credential("1"))
      assert_received :apple_jwks_fetched
      stub_jwks(self(), status: 503)
      assert {:ok, _} = verify(credential("1"))
      refute_received :apple_jwks_fetched

      reset()

      log =
        capture_log(fn ->
          assert {:error, :unavailable} = verify(credential("1"))
          assert {:error, :unavailable} = verify(credential("1"))
        end)

      assert log =~ "provider=apple_jwks"
      # Backoff: one fetch, no request storm while Apple is down.
      assert_received :apple_jwks_fetched
      refute_received :apple_jwks_fetched
    end
  end

  describe "configuration" do
    test "APPLE_SIGN_IN_CLIENT_IDS parsing" do
      assert Apple.parse_client_ids!(nil) == []
      assert Apple.parse_client_ids!(" , ") == []

      assert Apple.parse_client_ids!(
               " com.simplefit.boxing, ,com.simplefit.boxing.web,com.simplefit.boxing "
             ) == ["com.simplefit.boxing", "com.simplefit.boxing.web"]

      for bad <- ["simplefit", "com.simplefit.boxing,https://evil.example", "com..x", "com.a b"] do
        assert_raise ArgumentError, ~r/APPLE_SIGN_IN_CLIENT_IDS/, fn ->
          Apple.parse_client_ids!(bad)
        end
      end
    end

    test "without configured client ids every credential is refused as not configured" do
      original = Application.get_env(:simple_fit, Apple)
      Application.put_env(:simple_fit, Apple, Keyword.put(original, :client_ids, []))
      on_exit(fn -> Application.put_env(:simple_fit, Apple, original) end)

      assert {:error, :not_configured} = verify(credential("1"))

      log = capture_log([level: :warning], fn -> assert Apple.warn_if_not_configured() == :ok end)
      assert log =~ "apple sign-in not configured"
      assert log =~ "reason=not_configured"
    end

    test "the boot check is silent when configured" do
      assert capture_log([level: :debug], fn -> Apple.warn_if_not_configured() end) == ""
    end
  end
end
