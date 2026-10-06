defmodule SimpleFit.GoogleTokens do
  @moduledoc """
  Test Google ID tokens (ADR 0013): real RS256 JWTs signed with locally
  generated keys, and a `Req.Test` stub serving those keys as Google's JWKS.
  Nothing talks to Google.
  """

  alias SimpleFit.Identity.Google.Keys

  @web "111111111111-webclienttest.apps.googleusercontent.com"
  @ios "111111111111-iosclienttest.apps.googleusercontent.com"
  @android "111111111111-androidclienttest.apps.googleusercontent.com"

  def web_client, do: @web
  def ios_client, do: @ios
  def android_client, do: @android

  @doc "A cached RSA signing key for `kid` (generation is slow)."
  def key(kid \\ "test-key-1") do
    case :persistent_term.get({__MODULE__, kid}, nil) do
      nil ->
        jwk = JOSE.JWK.generate_key({:rsa, 2048})
        :persistent_term.put({__MODULE__, kid}, jwk)
        jwk

      jwk ->
        jwk
    end
  end

  @doc "Default claims of a valid web-client token for `sub`."
  def claims(sub, overrides \\ %{}) do
    now = System.os_time(:second)

    Map.merge(
      %{
        "iss" => "https://accounts.google.com",
        "aud" => @web,
        "sub" => sub,
        "iat" => now,
        "exp" => now + 3600,
        "email" => "person@example.com",
        "email_verified" => true,
        "name" => "Test Person"
      },
      overrides
    )
  end

  @doc "A signed token. `opts`: `:kid`, `:key` (signing key), `:header` overrides."
  def token(claims, opts \\ []) do
    kid = Keyword.get(opts, :kid, "test-key-1")
    jwk = Keyword.get(opts, :key, key(kid))

    header =
      Map.merge(
        %{"alg" => "RS256", "kid" => kid, "typ" => "JWT"},
        Keyword.get(opts, :header, %{})
      )

    {_, compact} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    compact
  end

  @doc "A valid token for `sub` (web audience unless overridden)."
  def valid_token(sub, overrides \\ %{}), do: token(claims(sub, overrides))

  @doc "The JWKS document publishing the public keys of `kids`."
  def jwks(kids \\ ["test-key-1"]) do
    %{
      "keys" =>
        Enum.map(kids, fn kid ->
          {_, public} = kid |> key() |> JOSE.JWK.to_public_map()
          Map.merge(public, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})
        end)
    }
  end

  @doc """
  Serves `body` (or a status) as Google's JWKS with `max-age`, sends
  `{:jwks_fetched}` to the test process on every fetch, and lets the key
  cache process use the stub.
  """
  def stub_jwks(test_pid, opts \\ []) do
    max_age = Keyword.get(opts, :max_age, 3600)
    status = Keyword.get(opts, :status, 200)
    body = Keyword.get_lazy(opts, :body, fn -> jwks(Keyword.get(opts, :kids, ["test-key-1"])) end)

    Req.Test.stub(Keys, fn conn ->
      send(test_pid, :jwks_fetched)

      conn
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=#{max_age}, must-revalidate")
      |> respond(status, body)
    end)

    Req.Test.allow(Keys, test_pid, Process.whereis(Keys))
    :ok
  end

  defp respond(conn, 200, body), do: Req.Test.json(conn, body)
  defp respond(conn, status, _body), do: Plug.Conn.send_resp(conn, status, "")

  @doc "Forgets cached keys; call in setup."
  def reset do
    Keys.flush()
  end
end
