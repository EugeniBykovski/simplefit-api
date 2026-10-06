defmodule SimpleFit.Accounts.GoogleAuthTest do
  # Not async: Google's signing keys are cached in one process.
  use SimpleFit.DataCase, async: false

  import SimpleFit.GoogleTokens

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{Identity, Session, User}

  @ip "203.0.113.20"

  setup do
    reset()
    stub_jwks(self())
    :ok
  end

  defp sign_in(token, ip \\ @ip), do: Accounts.authenticate_with_google(token, ip)

  test "an unknown Google subject creates one user with a google identity and a session" do
    assert {:ok,
            %{account: :created, credentials: %{session: session, refresh_token: "sfr_" <> _}}} =
             sign_in(valid_token("1234567890"))

    assert [%Identity{provider: :google, provider_subject: "1234567890", user_id: user_id}] =
             Repo.all(Identity)

    assert session.user_id == user_id
    assert Repo.aggregate(User, :count) == 1
  end

  test "repeat sign-in resolves the same user and starts an independent session" do
    {:ok, %{credentials: first}} = sign_in(valid_token("1234567890"))

    # Profile claims may change; the subject is the only key.
    {:ok, %{account: :existing, credentials: second}} =
      sign_in(valid_token("1234567890", %{"email" => "new@example.com", "name" => "Renamed"}))

    assert first.session.user_id == second.session.user_id
    refute first.session.id == second.session.id
    assert Repo.aggregate(Session, :count) == 2
    assert Repo.aggregate(User, :count) == 1
    assert {:ok, _} = Accounts.authenticate_access_token(first.access_token)
  end

  test "the same token may be exchanged twice (independent sessions, no replay store)" do
    token = valid_token("42")
    assert {:ok, %{account: :created}} = sign_in(token)
    assert {:ok, %{account: :existing}} = sign_in(token)
    assert Repo.aggregate(Session, :count) == 2
  end

  test "an email identity with the same address is never linked" do
    {:ok, email_user} = Accounts.register_user(:email, "person@example.com")

    {:ok, %{account: :created, credentials: %{session: session}}} =
      sign_in(valid_token("777", %{"email" => "person@example.com", "email_verified" => true}))

    refute session.user_id == email_user.id
    assert Repo.aggregate(User, :count) == 2
    assert {:ok, %{id: id}} = Accounts.resolve_user(:email, "person@example.com")
    assert id == email_user.id
  end

  test "every audience shape signs in to the same user" do
    {:ok, %{credentials: web}} = sign_in(valid_token("55"))

    {:ok, %{credentials: ios}} =
      sign_in(valid_token("55", %{"aud" => ios_client(), "azp" => ios_client()}))

    {:ok, %{credentials: android}} =
      sign_in(valid_token("55", %{"aud" => web_client(), "azp" => android_client()}))

    assert web.session.user_id == ios.session.user_id
    assert ios.session.user_id == android.session.user_id
  end

  test "invalid tokens and missing configuration" do
    assert {:error, :unauthorized} =
             sign_in(token(claims("1", %{"aud" => "1-x.apps.googleusercontent.com"})))

    assert {:error, %Ecto.Changeset{}} = sign_in(nil)
    assert {:error, %Ecto.Changeset{}} = sign_in("")

    reset()
    stub_jwks(self(), status: 500)
    assert {:error, :unavailable} = sign_in(valid_token("1"))
    assert Repo.aggregate(User, :count) == 0
  end

  test "rate limits: 30 per IP before verification, 20 per verified subject" do
    for _ <- 1..30, do: sign_in("garbage", "198.51.100.40")
    assert {:error, {:rate_limited, _}} = sign_in(valid_token("1"), "198.51.100.40")

    token = valid_token("99")
    for n <- 1..20, do: assert({:ok, _} = sign_in(token, "198.51.100.#{n}"))
    assert {:error, {:rate_limited, _}} = sign_in(token, "198.51.100.200")

    # Another subject is unaffected: limits never key on unverified claims.
    assert {:ok, _} = sign_in(valid_token("100"), "198.51.100.201")

    %{rows: rows} = Repo.query!("SELECT bucket FROM auth_rate_limits", [])
    refute inspect(rows) =~ "99"
  end
end
