defmodule SimpleFit.Accounts.SessionsTest do
  # Not async: one test temporarily changes the session policy in the app env.
  use SimpleFit.DataCase, async: false

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{RefreshToken, Session, Sessions, User}

  setup do
    {:ok, user} = Accounts.register_user(:email, "session-user@example.com")
    %{user: user}
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  describe "create_session/1" do
    test "creates one session for the user and issues both credentials", %{user: user} do
      assert {:ok, credentials} = Accounts.create_session(user)

      assert %Session{user_id: user_id, revoked_at: nil} = credentials.session
      assert user_id == user.id
      assert "sfa_" <> _ = credentials.access_token
      assert credentials.refresh_token =~ ~r/\Asfr_[A-Za-z0-9_-]{43}\z/
      assert count(Session) == 1
      assert count(RefreshToken) == 1
    end

    test "applies the configured lifetimes", %{user: user} do
      config = Sessions.config!()
      {:ok, credentials} = Accounts.create_session(user)
      now = DateTime.utc_now()

      assert_in_delta DateTime.diff(credentials.access_token_expires_at, now),
                      config.access_token_ttl,
                      2

      assert_in_delta DateTime.diff(credentials.refresh_token_expires_at, now),
                      config.refresh_token_ttl,
                      2

      assert_in_delta DateTime.diff(credentials.session.expires_at, now),
                      config.session_lifetime,
                      2
    end

    test "needs only the user, never a provider credential" do
      assert {:arity, 1} = Function.info(&Accounts.create_session/1, :arity)
    end

    test "fails for a user that no longer exists", %{user: user} do
      Repo.delete!(user)
      assert Accounts.create_session(user) == {:error, :not_found}
      assert count(Session) == 0
    end

    test "the same user can hold several independent sessions", %{user: user} do
      {:ok, a} = Accounts.create_session(user)
      {:ok, b} = Accounts.create_session(user)

      refute a.session.id == b.session.id
      assert {:ok, %{user: %User{id: id}}} = Accounts.authenticate_access_token(b.access_token)
      assert id == user.id

      :ok = Accounts.revoke_session({:access, a.access_token})
      assert Accounts.authenticate_access_token(a.access_token) == {:error, :unauthorized}
      assert {:ok, _viewer} = Accounts.authenticate_access_token(b.access_token)
      assert {:ok, _rotated} = Accounts.refresh_session(b.refresh_token)
    end
  end

  describe "authenticate_access_token/1" do
    setup %{user: user} do
      {:ok, credentials} = Accounts.create_session(user)
      %{credentials: credentials}
    end

    test "resolves exactly the session's user", %{credentials: c, user: user} do
      assert {:ok, %{user: %User{id: user_id}, session: %Session{id: session_id}}} =
               Accounts.authenticate_access_token(c.access_token)

      assert user_id == user.id
      assert session_id == c.session.id
    end

    test "rejects an expired access token", %{credentials: c} do
      ttl = Sessions.config!().access_token_ttl
      past = DateTime.add(DateTime.utc_now(:second), -(ttl + 1))
      expired = Sessions.sign_access_token_at(c.session.id, past)

      assert Accounts.authenticate_access_token(expired) == {:error, :unauthorized}

      fresh = Sessions.sign_access_token_at(c.session.id, DateTime.utc_now(:second))
      assert {:ok, _viewer} = Accounts.authenticate_access_token(fresh)
    end

    test "rejects malformed and tampered tokens", %{credentials: c} do
      "sfa_" <> signed = c.access_token
      [protected, payload, signature] = String.split(signed, ".")
      tampered = "sfa_" <> Enum.join([protected, payload, String.reverse(signature)], ".")

      for token <- ["", "garbage", "sfa_", signed, tampered, "Bearer " <> c.access_token, nil, 42] do
        assert Accounts.authenticate_access_token(token) == {:error, :unauthorized}
      end
    end

    test "rejects a token signed with another secret", %{credentials: c} do
      forged =
        "sfa_" <>
          Plug.Crypto.sign(String.duplicate("x", 64), "simplefit access token v1", c.session.id)

      assert Accounts.authenticate_access_token(forged) == {:error, :unauthorized}
    end

    test "a refresh token is not an access token", %{credentials: c} do
      assert Accounts.authenticate_access_token(c.refresh_token) == {:error, :unauthorized}
    end

    test "a revoked session is rejected immediately", %{credentials: c} do
      :ok = Sessions.revoke_session(c.session.id, :logout)
      assert Accounts.authenticate_access_token(c.access_token) == {:error, :unauthorized}
    end

    test "an expired session is rejected even with a fresh token", %{credentials: c} do
      past = DateTime.add(DateTime.utc_now(:second), -1)

      Repo.update_all(from(s in Session, where: s.id == ^c.session.id),
        set: [expires_at: past, inserted_at: DateTime.add(past, -10)]
      )

      assert Accounts.authenticate_access_token(c.access_token) == {:error, :unauthorized}
    end

    test "a deleted user's sessions disappear with it", %{credentials: c, user: user} do
      Repo.delete!(user)
      assert Accounts.authenticate_access_token(c.access_token) == {:error, :unauthorized}
      assert count(Session) == 0
      assert count(RefreshToken) == 0
    end
  end

  describe "refresh_session/1" do
    setup %{user: user} do
      {:ok, credentials} = Accounts.create_session(user)
      %{credentials: credentials}
    end

    test "rotates: new credentials for the same session", %{credentials: c} do
      assert {:ok, next} = Accounts.refresh_session(c.refresh_token)

      assert next.session.id == c.session.id
      refute next.refresh_token == c.refresh_token
      assert {:ok, _viewer} = Accounts.authenticate_access_token(next.access_token)
      assert Repo.aggregate(from(t in RefreshToken, where: is_nil(t.consumed_at)), :count) == 1
    end

    test "once its successor was presented, the old token can never refresh again", %{
      credentials: c
    } do
      {:ok, next} = Accounts.refresh_session(c.refresh_token)
      {:ok, _third} = Accounts.refresh_session(next.refresh_token)
      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
    end

    test "a replay after the successor was presented revokes the whole session", %{
      credentials: c
    } do
      {:ok, second} = Accounts.refresh_session(c.refresh_token)
      {:ok, next} = Accounts.refresh_session(second.refresh_token)

      # The successor's use proved its response arrived: the old token is
      # now reuse, however soon it comes back.
      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}

      assert %Session{revoked_reason: :refresh_reuse} = Repo.get!(Session, c.session.id)
      # The successor dies with the family, and so does every access token.
      assert Accounts.refresh_session(next.refresh_token) == {:error, :unauthorized}
      assert Accounts.authenticate_access_token(next.access_token) == {:error, :unauthorized}
      assert Accounts.authenticate_access_token(c.access_token) == {:error, :unauthorized}
      assert Accounts.authenticate_access_token(second.access_token) == {:error, :unauthorized}
    end

    test "reuse of any older token in the chain also revokes", %{credentials: c} do
      {:ok, second} = Accounts.refresh_session(c.refresh_token)
      {:ok, third} = Accounts.refresh_session(second.refresh_token)

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert Accounts.refresh_session(third.refresh_token) == {:error, :unauthorized}
      assert Repo.get!(Session, c.session.id).revoked_reason == :refresh_reuse
    end

    test "an expired refresh token is rejected and does not revoke", %{credentials: c} do
      hash = :crypto.hash(:sha256, c.refresh_token)
      past = DateTime.add(DateTime.utc_now(:second), -1)

      Repo.update_all(from(t in RefreshToken, where: t.token_hash == ^hash),
        set: [expires_at: past]
      )

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert Repo.get!(Session, c.session.id).revoked_at == nil
    end

    test "a revoked session cannot refresh", %{credentials: c} do
      :ok = Accounts.revoke_session({:access, c.access_token})
      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      # The failed attempt did not consume the token.
      assert Repo.aggregate(from(t in RefreshToken, where: is_nil(t.consumed_at)), :count) == 1
    end

    test "an expired session cannot refresh", %{credentials: c} do
      past = DateTime.add(DateTime.utc_now(:second), -1)

      Repo.update_all(from(s in Session, where: s.id == ^c.session.id),
        set: [expires_at: past, inserted_at: DateTime.add(past, -10)]
      )

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
    end

    test "refresh tokens never outlive their session", %{credentials: c} do
      soon = DateTime.add(DateTime.utc_now(:second), 60)
      Repo.update_all(from(s in Session, where: s.id == ^c.session.id), set: [expires_at: soon])

      {:ok, next} = Accounts.refresh_session(c.refresh_token)
      assert DateTime.compare(next.refresh_token_expires_at, soon) != :gt
      assert DateTime.compare(next.access_token_expires_at, soon) != :gt
    end

    test "rejects malformed, random and access tokens", %{credentials: c} do
      random = "sfr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      for token <- ["", "sfr_", "sfr_short", random, c.access_token, nil, 7, %{}] do
        assert Accounts.refresh_session(token) == {:error, :unauthorized}
      end

      assert Repo.get!(Session, c.session.id).revoked_at == nil
    end
  end

  describe "refresh_session/1: lost-response recovery (SF-75)" do
    setup %{user: user} do
      {:ok, credentials} = Accounts.create_session(user)
      %{credentials: credentials}
    end

    defp token_row(refresh_token),
      do: Repo.get_by!(RefreshToken, token_hash: :crypto.hash(:sha256, refresh_token))

    defp live_tokens(session_id),
      do:
        Repo.all(
          from t in RefreshToken, where: t.session_id == ^session_id and is_nil(t.consumed_at)
        )

    defp age_consumption(refresh_token, seconds) do
      hash = :crypto.hash(:sha256, refresh_token)
      at = DateTime.add(DateTime.utc_now(:second), -seconds)

      Repo.update_all(from(t in RefreshToken, where: t.token_hash == ^hash),
        set: [consumed_at: at]
      )
    end

    test "the token presented again before its successor was used recovers the session", %{
      credentials: c
    } do
      # The response carrying `lost` never reached the client.
      {:ok, lost} = Accounts.refresh_session(c.refresh_token)
      assert {:ok, recovered} = Accounts.refresh_session(c.refresh_token)

      assert recovered.session.id == c.session.id
      refute recovered.refresh_token in [c.refresh_token, lost.refresh_token]
      assert {:ok, _viewer} = Accounts.authenticate_access_token(recovered.access_token)
      assert Repo.get!(Session, c.session.id).revoked_at == nil

      # Exactly one live token: the recovered one, a child of the same token.
      assert [live] = live_tokens(c.session.id)
      assert live.id == token_row(recovered.refresh_token).id
      assert live.parent_id == token_row(c.refresh_token).id

      assert %RefreshToken{superseded_at: %DateTime{}, consumed_at: %DateTime{}} =
               token_row(lost.refresh_token)

      assert token_row(c.refresh_token).recoveries == 1
    end

    test "the superseded successor is reuse: two holders of one token collide", %{
      credentials: c
    } do
      # One holder of the token refreshes, another presents it too.
      {:ok, first} = Accounts.refresh_session(c.refresh_token)
      {:ok, second} = Accounts.refresh_session(c.refresh_token)

      assert Accounts.refresh_session(first.refresh_token) == {:error, :unauthorized}
      assert %Session{revoked_reason: :refresh_reuse} = Repo.get!(Session, c.session.id)
      assert Accounts.refresh_session(second.refresh_token) == {:error, :unauthorized}
      assert Accounts.authenticate_access_token(first.access_token) == {:error, :unauthorized}
      assert Accounts.authenticate_access_token(second.access_token) == {:error, :unauthorized}
    end

    test "the recovered token rotates normally; the old token is then reuse", %{credentials: c} do
      {:ok, _lost} = Accounts.refresh_session(c.refresh_token)
      {:ok, recovered} = Accounts.refresh_session(c.refresh_token)
      {:ok, next} = Accounts.refresh_session(recovered.refresh_token)

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert Repo.get!(Session, c.session.id).revoked_reason == :refresh_reuse
      assert Accounts.refresh_session(next.refresh_token) == {:error, :unauthorized}
    end

    test "successive lost responses recover up to the limit, then it is reuse", %{
      credentials: c
    } do
      limit = Sessions.config!().refresh_recovery_limit
      {:ok, _lost} = Accounts.refresh_session(c.refresh_token)

      for _ <- 1..limit do
        assert {:ok, _recovered} = Accounts.refresh_session(c.refresh_token)
        assert length(live_tokens(c.session.id)) == 1
      end

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert Repo.get!(Session, c.session.id).revoked_reason == :refresh_reuse
    end

    test "after the recovery window it is reuse", %{credentials: c} do
      window = Sessions.config!().refresh_recovery_window
      {:ok, lost} = Accounts.refresh_session(c.refresh_token)

      age_consumption(c.refresh_token, window)
      assert {:ok, recovered} = Accounts.refresh_session(c.refresh_token)

      # The window runs from the first consumption; recoveries never extend it.
      age_consumption(c.refresh_token, window + 1)
      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert Repo.get!(Session, c.session.id).revoked_reason == :refresh_reuse
      assert Accounts.refresh_session(recovered.refresh_token) == {:error, :unauthorized}
      assert Accounts.refresh_session(lost.refresh_token) == {:error, :unauthorized}
    end

    test "a token whose child has no recorded parent (issued before SF-75) is reuse", %{
      credentials: c
    } do
      {:ok, next} = Accounts.refresh_session(c.refresh_token)
      hash = :crypto.hash(:sha256, next.refresh_token)

      Repo.update_all(from(t in RefreshToken, where: t.token_hash == ^hash),
        set: [parent_id: nil]
      )

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert Repo.get!(Session, c.session.id).revoked_reason == :refresh_reuse
    end

    test "an expired consumed token is reuse, not a recovery", %{credentials: c} do
      {:ok, _next} = Accounts.refresh_session(c.refresh_token)
      hash = :crypto.hash(:sha256, c.refresh_token)
      past = DateTime.add(DateTime.utc_now(:second), -1)

      Repo.update_all(from(t in RefreshToken, where: t.token_hash == ^hash),
        set: [expires_at: past]
      )

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert Repo.get!(Session, c.session.id).revoked_reason == :refresh_reuse
    end

    test "a logged-out session cannot be recovered and keeps its reason", %{credentials: c} do
      {:ok, next} = Accounts.refresh_session(c.refresh_token)
      :ok = Accounts.revoke_session({:access, next.access_token})

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert Accounts.refresh_session(next.refresh_token) == {:error, :unauthorized}
      assert Repo.get!(Session, c.session.id).revoked_reason == :logout
      assert token_row(c.refresh_token).recoveries == 0
      assert [_still_unused] = live_tokens(c.session.id)
    end

    test "an expired session cannot be recovered", %{credentials: c} do
      {:ok, _next} = Accounts.refresh_session(c.refresh_token)
      past = DateTime.add(DateTime.utc_now(:second), -1)

      Repo.update_all(from(s in Session, where: s.id == ^c.session.id),
        set: [expires_at: past, inserted_at: DateTime.add(past, -10)]
      )

      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
      assert token_row(c.refresh_token).recoveries == 0
    end

    test "recovery stays inside its own session", %{credentials: c, user: user} do
      {:ok, other} = Accounts.create_session(user)
      {:ok, _lost} = Accounts.refresh_session(c.refresh_token)
      {:ok, recovered} = Accounts.refresh_session(c.refresh_token)

      assert recovered.session.id == c.session.id
      assert {:ok, _} = Accounts.refresh_session(other.refresh_token)
      assert Repo.get!(Session, other.session.id).revoked_at == nil
    end
  end

  describe "revoke_session/1 (logout)" do
    setup %{user: user} do
      {:ok, credentials} = Accounts.create_session(user)
      %{credentials: credentials}
    end

    test "by access token: the session can neither authenticate nor refresh", %{credentials: c} do
      assert :ok = Accounts.revoke_session({:access, c.access_token})

      session = Repo.get!(Session, c.session.id)
      assert session.revoked_reason == :logout
      assert Accounts.authenticate_access_token(c.access_token) == {:error, :unauthorized}
      assert Accounts.refresh_session(c.refresh_token) == {:error, :unauthorized}
    end

    test "by refresh token, current or consumed", %{credentials: c, user: user} do
      assert :ok = Accounts.revoke_session({:refresh, c.refresh_token})
      assert Accounts.authenticate_access_token(c.access_token) == {:error, :unauthorized}

      {:ok, other} = Accounts.create_session(user)
      {:ok, _next} = Accounts.refresh_session(other.refresh_token)
      assert :ok = Accounts.revoke_session({:refresh, other.refresh_token})
      assert Accounts.authenticate_access_token(other.access_token) == {:error, :unauthorized}
    end

    test "is idempotent and keeps the first revocation", %{credentials: c} do
      :ok = Accounts.revoke_session({:access, c.access_token})
      first = Repo.get!(Session, c.session.id)

      assert :ok = Accounts.revoke_session({:refresh, c.refresh_token})
      assert :ok = Accounts.revoke_session({:access, c.access_token})
      assert Repo.get!(Session, c.session.id) == first
    end

    test "unknown or malformed credentials are a silent no-op", %{credentials: c} do
      random = "sfr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      for credential <- [{:access, "nope"}, {:refresh, random}, {:refresh, "x"}, {:access, nil}] do
        assert Accounts.revoke_session(credential) == :ok
      end

      assert Repo.get!(Session, c.session.id).revoked_at == nil
    end
  end

  describe "database constraints" do
    setup %{user: user} do
      {:ok, credentials} = Accounts.create_session(user)
      %{credentials: credentials}
    end

    defp constraint_of(fun) do
      assert {:error, %Postgrex.Error{postgres: %{constraint: name}}} = fun.()
      name
    end

    defp insert_token(session_id, hash, consumed_at \\ nil) do
      Repo.query(
        "INSERT INTO session_refresh_tokens (id, session_id, token_hash, expires_at, consumed_at, inserted_at) " <>
          "VALUES ($1, $2, $3, now() + interval '1 day', $4, now())",
        [Ecto.UUID.bingenerate(), Ecto.UUID.dump!(session_id), hash, consumed_at]
      )
    end

    test "only one live refresh token per session", %{credentials: c} do
      assert constraint_of(fn -> insert_token(c.session.id, :crypto.strong_rand_bytes(32)) end) ==
               "session_refresh_tokens_one_active_index"

      assert {:ok, _} =
               insert_token(c.session.id, :crypto.strong_rand_bytes(32), DateTime.utc_now())
    end

    test "refresh hashes are unique SHA-256 digests", %{credentials: c} do
      hash = :crypto.hash(:sha256, c.refresh_token)

      assert constraint_of(fn -> insert_token(c.session.id, hash, DateTime.utc_now()) end) ==
               "session_refresh_tokens_token_hash_index"

      assert constraint_of(fn -> insert_token(c.session.id, "short", DateTime.utc_now()) end) ==
               "token_hash_is_sha256"
    end

    test "only a consumed token can be superseded; recoveries are bounded", %{credentials: c} do
      hash = :crypto.hash(:sha256, c.refresh_token)

      assert constraint_of(fn ->
               Repo.query(
                 "UPDATE session_refresh_tokens SET superseded_at = now() WHERE token_hash = $1",
                 [hash]
               )
             end) == "superseded_is_consumed"

      assert constraint_of(fn ->
               Repo.query(
                 "UPDATE session_refresh_tokens SET recoveries = 101 WHERE token_hash = $1",
                 [hash]
               )
             end) == "recoveries_bounded"
    end

    test "a refresh token needs its session" do
      assert constraint_of(fn ->
               insert_token(Ecto.UUID.generate(), :crypto.strong_rand_bytes(32))
             end) ==
               "session_refresh_tokens_session_id_fkey"
    end

    test "revocation fields are consistent", %{credentials: c} do
      id = Ecto.UUID.dump!(c.session.id)

      assert constraint_of(fn ->
               Repo.query("UPDATE sessions SET revoked_at = now() WHERE id = $1", [id])
             end) == "revocation_consistent"

      assert constraint_of(fn ->
               Repo.query(
                 "UPDATE sessions SET revoked_at = now(), revoked_reason = 'stolen' WHERE id = $1",
                 [id]
               )
             end) == "revocation_consistent"
    end

    test "a session needs its user and a future expiry", %{credentials: c} do
      assert constraint_of(fn ->
               Repo.query(
                 "INSERT INTO sessions (id, user_id, expires_at, inserted_at, updated_at) VALUES ($1, $2, now() + interval '1 day', now(), now())",
                 [Ecto.UUID.bingenerate(), Ecto.UUID.bingenerate()]
               )
             end) == "sessions_user_id_fkey"

      assert constraint_of(fn ->
               Repo.query("UPDATE sessions SET expires_at = inserted_at WHERE id = $1", [
                 Ecto.UUID.dump!(c.session.id)
               ])
             end) == "expires_after_creation"
    end
  end

  describe "configuration" do
    test "the production policy is 15 minutes / 30 days / 90 days, recovery 60 s × 10, no grace" do
      config = Sessions.config!()

      assert Map.keys(config) |> Enum.sort() ==
               [
                 :access_token_ttl,
                 :refresh_recovery_limit,
                 :refresh_recovery_window,
                 :refresh_token_ttl,
                 :secret_key_base,
                 :session_lifetime
               ]

      assert %{
               access_token_ttl: 900,
               refresh_token_ttl: 2_592_000,
               session_lifetime: 7_776_000,
               refresh_recovery_window: 60,
               refresh_recovery_limit: 10
             } = config

      refute Keyword.has_key?(Application.get_env(:simple_fit, Sessions), :refresh_reuse_grace)
    end

    test "rejects inconsistent or missing settings" do
      original = Application.get_env(:simple_fit, Sessions)
      on_exit(fn -> Application.put_env(:simple_fit, Sessions, original) end)

      for {key, value} <- [
            access_token_ttl: 0,
            refresh_token_ttl: 60,
            session_lifetime: 60,
            refresh_recovery_window: 0,
            refresh_recovery_window: 900,
            refresh_recovery_window: nil,
            refresh_recovery_limit: 0,
            refresh_recovery_limit: 101,
            secret_key_base: "too-short",
            secret_key_base: nil
          ] do
        Application.put_env(:simple_fit, Sessions, Keyword.put(original, key, value))
        assert_raise ArgumentError, fn -> Sessions.config!() end
      end
    end
  end

  describe "privacy" do
    test "stored records hold no secret and inspect hides the hash", %{user: user} do
      {:ok, c} = Accounts.create_session(user)
      [token] = Repo.all(RefreshToken)
      raw_hash = Base.encode16(token.token_hash, case: :lower)

      refute inspect(token) =~ raw_hash
      refute inspect(token) =~ c.refresh_token
      refute inspect(Repo.all(Session)) =~ c.refresh_token

      assert Session.__schema__(:fields) ==
               [
                 :id,
                 :user_id,
                 :expires_at,
                 :revoked_at,
                 :revoked_reason,
                 :inserted_at,
                 :updated_at
               ]

      assert RefreshToken.__schema__(:fields) ==
               [
                 :id,
                 :session_id,
                 :token_hash,
                 :expires_at,
                 :consumed_at,
                 :parent_id,
                 :superseded_at,
                 :recoveries,
                 :inserted_at
               ]
    end
  end
end
