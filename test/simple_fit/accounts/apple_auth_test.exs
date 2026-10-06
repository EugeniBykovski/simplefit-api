defmodule SimpleFit.Accounts.AppleAuthTest do
  # Not async: Apple's signing keys are cached in one process.
  use SimpleFit.DataCase, async: false

  import SimpleFit.AppleTokens

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{Identity, Session, User}

  @ip "203.0.113.30"

  setup do
    reset()
    stub_jwks(self())
    :ok
  end

  defp sign_in(%{id_token: token, nonce: nonce}, ip \\ @ip),
    do: Accounts.authenticate_with_apple(token, nonce, ip)

  test "an unknown Apple subject creates one user with an apple identity and a session" do
    assert {:ok,
            %{account: :created, credentials: %{session: session, refresh_token: "sfr_" <> _}}} =
             sign_in(credential("001234.abcdef.0987"))

    assert [%Identity{provider: :apple, provider_subject: "001234.abcdef.0987", user_id: user_id}] =
             Repo.all(Identity)

    assert session.user_id == user_id
    assert Repo.aggregate(User, :count) == 1
  end

  test "repeat sign-in resolves the same user; missing or changed email/name changes nothing" do
    {:ok, %{credentials: first}} = sign_in(credential("001234.abcdef.0987"))
    [identity] = Repo.all(Identity)

    # A later authorization carries no email, or a different relay address.
    for overrides <- [
          %{"email" => nil, "is_private_email" => nil, "email_verified" => nil},
          %{"email" => "other@privaterelay.appleid.com"},
          %{"email" => "person@example.com", "is_private_email" => "false"}
        ] do
      {:ok, %{account: :existing, credentials: again}} =
        sign_in(credential("001234.abcdef.0987", overrides))

      assert again.session.user_id == first.session.user_id
    end

    assert Repo.all(Identity) == [identity]
    assert Repo.aggregate(User, :count) == 1
    assert Repo.aggregate(Session, :count) == 4
  end

  test "web (Services ID) and native (bundle id) tokens for one subject are one user" do
    {:ok, %{credentials: native}} = sign_in(credential("shared-sub"))

    {:ok, %{account: :existing, credentials: web}} =
      sign_in(credential("shared-sub", %{"aud" => web_client()}))

    assert native.session.user_id == web.session.user_id
  end

  test "an email or Google identity with the same address is never linked" do
    {:ok, email_user} = Accounts.register_user(:email, "person@example.com")
    {:ok, google_user} = Accounts.register_user(:google, "google-sub-1")

    {:ok, %{account: :created, credentials: %{session: session}}} =
      sign_in(
        credential("777", %{
          "email" => "person@example.com",
          "email_verified" => "true",
          "is_private_email" => "false"
        })
      )

    refute session.user_id in [email_user.id, google_user.id]
    assert Repo.aggregate(User, :count) == 3
  end

  test "private relay email users sign in like anyone else" do
    assert {:ok, %{account: :created}} =
             sign_in(credential("relay-user", %{"email" => "xyz@privaterelay.appleid.com"}))
  end

  test "invalid credentials, validation and missing keys" do
    raw = raw_nonce()

    assert {:error, :unauthorized} =
             sign_in(%{id_token: token(claims("1", raw, %{"aud" => "com.other"})), nonce: raw})

    assert {:error, :unauthorized} =
             sign_in(%{id_token: token(claims("1", raw)), nonce: raw_nonce()})

    for {token, nonce, field} <- [
          {nil, raw, :id_token},
          {"", raw, :id_token},
          {token(claims("1", raw)), nil, :nonce},
          {token(claims("1", raw)), "", :nonce},
          {token(claims("1", raw)), "short", :nonce},
          {token(claims("1", raw)), String.duplicate("a", 129), :nonce},
          {token(claims("1", raw)), String.duplicate("a", 40) <> "+/=", :nonce},
          {token(claims("1", raw)), 42, :nonce}
        ] do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Accounts.authenticate_with_apple(token, nonce, @ip)

      assert Keyword.has_key?(errors, field), inspect({nonce, errors})
    end

    reset()
    stub_jwks(self(), status: 500)
    assert {:error, :unavailable} = sign_in(credential("1"))
    assert Repo.aggregate(User, :count) == 0
  end

  test "rate limits: 30 per IP before verification, 20 per verified subject" do
    raw = raw_nonce()
    for _ <- 1..30, do: sign_in(%{id_token: "garbage", nonce: raw}, "198.51.100.50")
    assert {:error, {:rate_limited, _}} = sign_in(credential("1"), "198.51.100.50")

    for n <- 1..20, do: assert({:ok, _} = sign_in(credential("sub-99"), "198.51.100.#{n}"))
    assert {:error, {:rate_limited, _}} = sign_in(credential("sub-99"), "198.51.100.200")

    # Another subject is unaffected: limits never key on unverified claims.
    assert {:ok, _} = sign_in(credential("sub-100"), "198.51.100.201")

    %{rows: rows} = Repo.query!("SELECT bucket, key_digest FROM auth_rate_limits", [])
    refute inspect(rows, limit: :infinity) =~ "sub-99"
    assert Enum.any?(rows, fn [bucket, _] -> bucket == "apple_auth:subject" end)

    # Google's buckets are separate.
    refute Enum.any?(rows, fn [bucket, _] -> String.starts_with?(bucket, "google_auth") end)
  end
end
