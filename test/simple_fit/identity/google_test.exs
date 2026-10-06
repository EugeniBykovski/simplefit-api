defmodule SimpleFit.Identity.GoogleTest do
  # Not async: the signing-key cache is one supervised process.
  use ExUnit.Case, async: false

  import SimpleFit.GoogleTokens

  alias SimpleFit.Identity
  alias SimpleFit.Identity.Google

  setup do
    reset()
    stub_jwks(self())
    :ok
  end

  defp verify(token), do: Identity.verify(:google, token)

  describe "valid tokens" do
    test "web, iOS and Android-shaped tokens resolve to the subject only" do
      for claims <- [
            claims("1001"),
            claims("1001", %{"aud" => ios_client(), "azp" => ios_client()}),
            # Android: aud is the web client, azp the Android client.
            claims("1001", %{"aud" => web_client(), "azp" => android_client()}),
            claims("1001", %{"iss" => "accounts.google.com"})
          ] do
        assert {:ok, %{provider: :google, subject: "1001"} = result} = verify(token(claims))
        refute Map.has_key?(result, :email)
      end
    end

    test "small clock skew is tolerated" do
      now = System.os_time(:second)
      assert {:ok, _} = verify(token(claims("1", %{"iat" => now + 20, "nbf" => now + 20})))
      assert {:ok, _} = verify(token(claims("1", %{"exp" => now - 20})))
    end
  end

  describe "invalid tokens are rejected with a bounded reason" do
    test "structure, algorithm and signature" do
      assert {:error, {:rejected, :malformed}} = verify("not.a.jwt")
      assert {:error, {:rejected, :malformed}} = verify("garbage")
      assert {:error, {:rejected, :malformed}} = verify(123)

      # Signed by a key Google does not publish under that kid.
      forged = token(claims("1"), key: JOSE.JWK.generate_key({:rsa, 2048}))
      assert {:error, {:rejected, :bad_signature}} = verify(forged)

      # alg none and HMAC (with the public key as secret) are never accepted.
      [header, payload, _sig] = String.split(valid_token("1"), ".")
      none = Base.url_encode64(~s({"alg":"none","kid":"test-key-1"}), padding: false)
      assert {:error, {:rejected, :unsupported_algorithm}} = verify("#{none}.#{payload}.")

      hmac = JOSE.JWK.from_oct("secret")

      {_, hs256} =
        JOSE.JWT.sign(hmac, %{"alg" => "HS256", "kid" => "test-key-1"}, claims("1"))
        |> JOSE.JWS.compact()

      assert {:error, {:rejected, :unsupported_algorithm}} = verify(hs256)

      no_kid = Base.url_encode64(~s({"alg":"RS256"}), padding: false)
      assert {:error, {:rejected, :unsupported_algorithm}} = verify("#{no_kid}.#{payload}.x")
      assert header
    end

    test "issuer, audience and authorized party" do
      assert {:error, {:rejected, :issuer}} =
               verify(token(claims("1", %{"iss" => "https://evil.example"})))

      assert {:error, {:rejected, :audience}} =
               verify(token(claims("1", %{"aud" => "999-other.apps.googleusercontent.com"})))

      assert {:error, {:rejected, :audience}} =
               verify(token(claims("1", %{"aud" => [web_client()]})))

      # The audience is ours but the token was issued to another client.
      assert {:error, {:rejected, :authorized_party}} =
               verify(token(claims("1", %{"azp" => "999-intruder.apps.googleusercontent.com"})))
    end

    test "time" do
      now = System.os_time(:second)

      assert {:error, {:rejected, :expired}} = verify(token(claims("1", %{"exp" => now - 120})))
      assert {:error, {:rejected, :expired}} = verify(token(Map.delete(claims("1"), "exp")))

      assert {:error, {:rejected, :not_yet_valid}} =
               verify(token(claims("1", %{"iat" => now + 600})))

      assert {:error, {:rejected, :not_yet_valid}} =
               verify(token(Map.delete(claims("1"), "iat")))

      assert {:error, {:rejected, :not_yet_valid}} =
               verify(token(claims("1", %{"nbf" => now + 600})))
    end

    test "subject" do
      for sub <- [nil, "", 42, "has space", String.duplicate("1", 256), "naïve"] do
        claims = if is_nil(sub), do: Map.delete(claims("x"), "sub"), else: claims(sub)
        assert {:error, {:rejected, :subject}} = verify(token(claims)), inspect(sub)
      end

      assert {:ok, _} = verify(token(claims(String.duplicate("1", 255))))
    end
  end

  describe "signing keys" do
    test "are fetched once and cached for max-age" do
      assert {:ok, _} = verify(valid_token("1"))
      assert {:ok, _} = verify(valid_token("2"))
      assert_received :jwks_fetched
      refute_received :jwks_fetched
    end

    test "expire after max-age and are fetched again" do
      stub_jwks(self(), max_age: 1)
      assert {:ok, _} = verify(valid_token("1"))
      assert_received :jwks_fetched
      Process.sleep(1_100)
      assert {:ok, _} = verify(valid_token("1"))
      assert_received :jwks_fetched
    end

    test "an unknown kid triggers at most one refresh per minute (no fetch storm)" do
      unknown = token(claims("1"), kid: "rotated-key")

      # Empty cache: one fetch, and Google does not know the key.
      assert {:error, {:rejected, :unknown_key}} = verify(unknown)
      assert_received :jwks_fetched

      # Random kids right after a refresh never reach Google again.
      for n <- 1..5 do
        assert {:error, {:rejected, :unknown_key}} =
                 verify(token(claims("1"), kid: "random-#{n}"))
      end

      refute_received :jwks_fetched
      assert {:ok, _} = verify(valid_token("1"))
    end

    test "key rotation: a new kid published by Google is picked up" do
      stub_jwks(self(), kids: ["test-key-1", "test-key-2"])
      assert {:ok, _} = verify(token(claims("1"), kid: "test-key-2"))
    end

    test "Google outage with valid cached keys: verification continues" do
      assert {:ok, _} = verify(valid_token("1"))
      stub_jwks(self(), status: 503)
      assert {:ok, _} = verify(valid_token("1"))
    end

    test "Google outage without valid keys: fail closed" do
      stub_jwks(self(), status: 503)
      assert {:error, :unavailable} = verify(valid_token("1"))
      # Backoff: no request storm while Google is down.
      assert {:error, :unavailable} = verify(valid_token("1"))
      assert_received :jwks_fetched
      refute_received :jwks_fetched
    end

    test "a malformed key set never replaces valid keys, and alone fails closed" do
      assert {:ok, _} = verify(valid_token("1"))
      stub_jwks(self(), body: %{"keys" => "nope"})
      assert {:error, {:rejected, :unknown_key}} = verify(token(claims("1"), kid: "other"))
      # Still-valid keys survived; the failed refresh made the unknown kid an outage.
      assert {:ok, _} = verify(valid_token("1"))

      reset()
      stub_jwks(self(), body: %{"keys" => [%{"kty" => "EC", "kid" => "x"}]})
      assert {:error, :unavailable} = verify(valid_token("1"))
    end
  end

  describe "configuration" do
    test "GOOGLE_OAUTH_CLIENT_IDS parsing" do
      assert Google.parse_client_ids!(nil) == []
      assert Google.parse_client_ids!(" , ") == []

      assert Google.parse_client_ids!(
               " 1-a.apps.googleusercontent.com, ,2-b.apps.googleusercontent.com,1-a.apps.googleusercontent.com "
             ) ==
               ["1-a.apps.googleusercontent.com", "2-b.apps.googleusercontent.com"]

      for bad <- [
            "web-client",
            "1-a.apps.googleusercontent.com,https://evil.example",
            "1-A.apps.googleusercontent.com"
          ] do
        assert_raise ArgumentError, fn -> Google.parse_client_ids!(bad) end
      end
    end

    test "without configured client ids every token is refused as unavailable" do
      original = Application.get_env(:simple_fit, Google)
      Application.put_env(:simple_fit, Google, Keyword.put(original, :client_ids, []))
      on_exit(fn -> Application.put_env(:simple_fit, Google, original) end)

      assert {:error, :not_configured} = verify(valid_token("1"))
    end
  end
end
