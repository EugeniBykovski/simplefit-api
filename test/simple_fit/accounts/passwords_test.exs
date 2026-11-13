defmodule SimpleFit.Accounts.PasswordsTest do
  @moduledoc "SF-157: the optional password credential (ADR 0012 amendment)."

  use SimpleFit.DataCase, async: true

  import ExUnit.CaptureLog
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.EmailAuth.Challenge
  alias SimpleFit.Accounts.{PasswordCredential, SecurityEvent, Session, User}
  alias SimpleFit.Operators.{Grant, Operator}

  @ip "203.0.113.157"
  @password "correct horse battery staple"

  defp email_user!(address) do
    {:ok, user} = Accounts.register_user(:email, address)
    user
  end

  defp address, do: "pw-#{System.unique_integer([:positive])}@example.com"

  defp request_code!(address) do
    {:ok, %{expires_in_seconds: _, resend_after_seconds: _}} =
      Accounts.request_password_reset(address, @ip)

    code_from(last_email_to(address))
  end

  # An email account with a password set through the emailed code, as a person would.
  defp with_password!(address, password \\ @password) do
    _ = email_user!(address)
    :ok = Accounts.reset_password(address, request_code!(address), password, @ip)
    reset_rate_limits()
    address
  end

  defp live_sessions(%User{id: id}),
    do:
      Repo.aggregate(from(s in Session, where: s.user_id == ^id and is_nil(s.revoked_at)), :count)

  defp wrong(code), do: code |> String.to_integer() |> Kernel.+(1) |> rem(1_000_000) |> pad()
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  describe "setting a password with an emailed code" do
    test "stores only an Argon2id hash, records the event and signs nobody in" do
      address = address()
      user = email_user!(address)
      {:ok, %{session: _}} = Accounts.create_session(user)

      code = request_code!(address)
      message = last_email_to(address)
      assert message.subject == "Your SimpleFit password code: #{code}"
      refute message.text =~ "http"

      assert :ok = Accounts.reset_password(address, code, @password, @ip)

      credential = Repo.get_by!(PasswordCredential, user_id: user.id)
      assert "$argon2id$" <> _ = credential.password_hash
      refute credential.password_hash =~ @password
      refute inspect(credential) =~ "argon2"

      assert [%SecurityEvent{event: :password_set, session_id: nil}] =
               Repo.all(from(e in SecurityEvent, where: e.user_id == ^user.id))

      # Every session of the account was signed out; none was started.
      assert live_sessions(user) == 0
      assert Accounts.password_set?(user)

      assert [%Challenge{purpose: :password_reset, closed_reason: :code_verified}] =
               Enum.filter(challenges(), &(&1.purpose == :password_reset))
    end

    test "answers the same for unknown addresses and sends nothing" do
      unknown = address()
      assert {:ok, %{expires_in_seconds: 600}} = Accounts.request_password_reset(unknown, @ip)
      assert emails_to(unknown) == []
      # A decoy challenge exists, so a guessed code is simply wrong.
      assert {:error, :code_invalid} = Accounts.reset_password(unknown, "123456", @password, @ip)
      refute Repo.exists?(PasswordCredential)
    end

    test "the code is single-use, purpose-bound, expires and stops after five wrong codes" do
      address = address()
      user = email_user!(address)
      code = request_code!(address)

      # An E17 sign-in code never sets a password.
      {:ok, _} = Accounts.request_email_sign_in(address, @ip)
      sign_in_code = code_from(last_email_to(address))

      if sign_in_code != code do
        assert {:error, :code_invalid} =
                 Accounts.reset_password(address, sign_in_code, @password, @ip)
      end

      assert :ok = Accounts.reset_password(address, code, @password, @ip)
      # Replay.
      assert {:error, :code_expired} =
               Accounts.reset_password(address, code, "another passphrase!", @ip)

      reset_rate_limits()
      code = request_code!(address)
      expire_challenges()

      assert {:error, :code_expired} =
               Accounts.reset_password(address, code, "another passphrase!", @ip)

      reset_rate_limits()
      code = request_code!(address)

      for _ <- 1..4 do
        assert {:error, :code_invalid} =
                 Accounts.reset_password(address, wrong(code), "another passphrase!", @ip)
      end

      assert {:error, :code_invalid} =
               Accounts.reset_password(address, wrong(code), "another passphrase!", @ip)

      assert {:error, :code_expired} =
               Accounts.reset_password(address, code, "another passphrase!", @ip)

      assert {:ok, _} = Accounts.password_sign_in(address, @password, @ip)
      assert Repo.aggregate(from(e in SecurityEvent, where: e.user_id == ^user.id), :count) == 1
    end

    test "a weak password is refused before the code is used" do
      address = address()
      _ = email_user!(address)
      code = request_code!(address)

      assert {:error, %Ecto.Changeset{} = short} =
               Accounts.reset_password(address, code, "short", @ip)

      assert %{password: [_]} = errors_on(short)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.reset_password(address, code, String.duplicate("a", 129), @ip)

      assert {:error, %Ecto.Changeset{} = own} =
               Accounts.reset_password(address, code, String.upcase(address), @ip)

      assert %{password: ["must not be your email address"]} = errors_on(own)

      assert :ok = Accounts.reset_password(address, code, @password, @ip)
    end

    test "a reset replaces the password, signs out everywhere and the old one stops working" do
      address = with_password!(address())
      {:ok, %{session: _}} = Accounts.password_sign_in(address, @password, @ip)

      user =
        Repo.one!(
          from(u in User, join: i in assoc(u, :identities), where: i.provider_subject == ^address)
        )

      assert live_sessions(user) == 1

      :ok =
        Accounts.reset_password(address, request_code!(address), "a brand new passphrase", @ip)

      assert live_sessions(user) == 0

      assert Repo.exists?(
               from(s in Session,
                 where: s.user_id == ^user.id and s.revoked_reason == :password_changed
               )
             )

      reset_rate_limits()
      assert {:error, :invalid_credentials} = Accounts.password_sign_in(address, @password, @ip)
      assert {:ok, _} = Accounts.password_sign_in(address, "a brand new passphrase", @ip)

      assert [:password_set, :password_reset] =
               Repo.all(
                 from(e in SecurityEvent,
                   where: e.user_id == ^user.id,
                   order_by: e.occurred_at,
                   select: e.event
                 )
               )
    end
  end

  describe "signing in" do
    test "starts a session for the right password and nothing else: no operator, no grant" do
      address = with_password!(address())

      assert {:ok, %{session: %Session{}, access_token: _, refresh_token: _}} =
               Accounts.password_sign_in(String.upcase(address), @password, @ip)

      assert Repo.aggregate(Operator, :count) == 0
      assert Repo.aggregate(Grant, :count) == 0
    end

    test "a wrong password, an unknown address and an account without a password answer alike" do
      with_pw = with_password!(address())
      no_pw = address()
      _ = email_user!(no_pw)

      for {email, password} <- [
            {with_pw, "wrong wrong wrong"},
            {address(), @password},
            {no_pw, @password},
            {with_pw, String.duplicate("x", 5_000)}
          ] do
        assert {:error, :invalid_credentials} = Accounts.password_sign_in(email, password, @ip)
      end
    end

    test "is limited per address and per client" do
      address = with_password!(address())

      for _ <- 1..5 do
        assert {:error, :invalid_credentials} =
                 Accounts.password_sign_in(address, "nope nope nope", @ip)
      end

      # Even the right password waits now: the limit doesn't depend on the answer.
      assert {:error, {:rate_limited, _}} = Accounts.password_sign_in(address, @password, @ip)

      reset_rate_limits()

      for n <- 1..30 do
        Accounts.password_sign_in("other-#{n}@example.com", "nope nope nope", "198.51.100.9")
      end

      assert {:error, {:rate_limited, _}} =
               Accounts.password_sign_in(address, @password, "198.51.100.9")

      assert {:ok, _} = Accounts.password_sign_in(address, @password, @ip)
    end

    test "a suspended account gets no session" do
      address = with_password!(address())

      user =
        Repo.one!(
          from(u in User, join: i in assoc(u, :identities), where: i.provider_subject == ^address)
        )

      Repo.insert_all("user_account_states", [
        %{
          user_id: Ecto.UUID.dump!(user.id),
          status: "suspended",
          revision: 1,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])

      assert {:error, :account_suspended} = Accounts.password_sign_in(address, @password, @ip)
    end

    test "nothing about the password reaches the logs" do
      address = with_password!(address())

      log =
        capture_log([level: :debug], fn ->
          Accounts.password_sign_in(address, @password, @ip)
          Accounts.password_sign_in(address, "wrong wrong wrong", @ip)
        end)

      refute log =~ @password
      refute log =~ "argon2"
      refute log =~ address
    end
  end

  describe "changing a password" do
    test "needs the current one, keeps this session and signs out the others" do
      address = with_password!(address())
      {:ok, %{session: here}} = Accounts.password_sign_in(address, @password, @ip)
      {:ok, %{session: _other}} = Accounts.password_sign_in(address, @password, @ip)
      user = Repo.get!(User, here.user_id)

      assert {:error, :invalid_credentials} =
               Accounts.change_password(user, here, "not the password", "a brand new passphrase")

      assert :ok = Accounts.change_password(user, here, @password, "a brand new passphrase")

      assert [%Session{id: id}] =
               Repo.all(from(s in Session, where: s.user_id == ^user.id and is_nil(s.revoked_at)))

      assert id == here.id

      assert %SecurityEvent{event: :password_changed, session_id: ^id} =
               Repo.one!(from(e in SecurityEvent, where: e.event == :password_changed))

      reset_rate_limits()
      assert {:ok, _} = Accounts.password_sign_in(address, "a brand new passphrase", @ip)
    end

    test "an account without a password sets one with a code, not by changing" do
      address = address()
      user = email_user!(address)
      {:ok, %{session: session}} = Accounts.create_session(user)

      assert {:error, :password_not_set} =
               Accounts.change_password(
                 user,
                 session,
                 "anything at all",
                 "a brand new passphrase"
               )

      refute Accounts.password_set?(user)
    end

    test "a revoked session can't change it" do
      address = with_password!(address())
      {:ok, %{session: session}} = Accounts.password_sign_in(address, @password, @ip)
      user = Repo.get!(User, session.user_id)

      Repo.update_all(from(s in Session, where: s.id == ^session.id),
        set: [revoked_at: DateTime.truncate(DateTime.utc_now(), :second), revoked_reason: :logout]
      )

      assert {:error, :unauthorized} =
               Accounts.change_password(user, session, @password, "a brand new passphrase")
    end
  end

  test "security events are append-only" do
    address = with_password!(address())

    event =
      Repo.one!(
        from(e in SecurityEvent,
          join: i in SimpleFit.Accounts.Identity,
          on: i.user_id == e.user_id,
          where: i.provider_subject == ^address
        )
      )

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.update_all(from(e in SecurityEvent, where: e.id == ^event.id),
        set: [event: :password_changed]
      )
    end
  end
end
