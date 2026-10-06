defmodule SimpleFit.AppleTokens do
  @moduledoc """
  Test Sign in with Apple identity tokens (ADR 0014): real RS256 JWTs signed
  with locally generated keys, raw nonces and their SHA-256, and a `Req.Test`
  stub serving the keys as Apple's JWKS. Nothing talks to Apple.
  """

  alias SimpleFit.Identity.Apple.Keys

  @native "com.simplefit.test"
  @web "com.simplefit.test.web"

  def native_client, do: @native
  def web_client, do: @web

  @doc "A cached RSA signing key for `kid` (generation is slow)."
  def key(kid \\ "apple-key-1") do
    case :persistent_term.get({__MODULE__, kid}, nil) do
      nil ->
        jwk = JOSE.JWK.generate_key({:rsa, 2048})
        :persistent_term.put({__MODULE__, kid}, jwk)
        jwk

      jwk ->
        jwk
    end
  end

  @doc "A raw nonce as the clients make it: 32 random bytes, base64url (43 characters)."
  def raw_nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "What the clients send to Apple: the lowercase hex SHA-256 of the raw nonce."
  def hashed(raw), do: :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)

  @doc """
  Default claims of a valid native token for `sub` bound to `raw` nonce,
  including the attributes Apple may add and SimpleFit ignores.
  """
  def claims(sub, raw, overrides \\ %{}) do
    now = System.os_time(:second)

    Map.merge(
      %{
        "iss" => "https://appleid.apple.com",
        "aud" => @native,
        "sub" => sub,
        "iat" => now,
        "exp" => now + 600,
        "nonce" => hashed(raw),
        "nonce_supported" => true,
        "email" => "abc123@privaterelay.appleid.com",
        "email_verified" => "true",
        "is_private_email" => "true",
        "real_user_status" => 2,
        "auth_time" => now
      },
      overrides
    )
  end

  @doc "A signed token. `opts`: `:kid`, `:key` (signing key), `:header` overrides."
  def token(claims, opts \\ []) do
    kid = Keyword.get(opts, :kid, "apple-key-1")
    jwk = Keyword.get(opts, :key, key(kid))
    header = Map.merge(%{"alg" => "RS256", "kid" => kid}, Keyword.get(opts, :header, %{}))

    {_, compact} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    compact
  end

  @doc "A valid `%{id_token, nonce}` credential for `sub` (native audience unless overridden)."
  def credential(sub, overrides \\ %{}) do
    raw = raw_nonce()
    %{id_token: token(claims(sub, raw, overrides)), nonce: raw}
  end

  @doc "The JWKS document publishing the public keys of `kids`."
  def jwks(kids \\ ["apple-key-1"]) do
    %{
      "keys" =>
        Enum.map(kids, fn kid ->
          {_, public} = kid |> key() |> JOSE.JWK.to_public_map()
          Map.merge(public, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})
        end)
    }
  end

  @doc """
  Serves `body` (or a status) as Apple's JWKS with Apple's `no-store` cache
  header, sends `:apple_jwks_fetched` to the test process on every fetch, and
  lets the key cache process use the stub.
  """
  def stub_jwks(test_pid, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    body =
      Keyword.get_lazy(opts, :body, fn -> jwks(Keyword.get(opts, :kids, ["apple-key-1"])) end)

    Req.Test.stub(Keys, fn conn ->
      send(test_pid, :apple_jwks_fetched)

      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> respond(status, body)
    end)

    Req.Test.allow(Keys, test_pid, Process.whereis(Keys))
    :ok
  end

  defp respond(conn, 200, body), do: Req.Test.json(conn, body)
  defp respond(conn, status, _body), do: Plug.Conn.send_resp(conn, status, "")

  @doc "Forgets cached keys; call in setup."
  def reset, do: Keys.flush()
end
