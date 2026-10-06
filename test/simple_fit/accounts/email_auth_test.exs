defmodule SimpleFit.Accounts.EmailAuthTest do
  use SimpleFit.DataCase, async: true

  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.EmailAuth.{Challenge, CleanupWorker, Secrets}
  alias SimpleFit.Accounts.{Identity, Session, User}

  @ip "203.0.113.7"

  defp register_request(email, ip \\ @ip) do
    {:ok, result} = Accounts.request_email_registration(email, ip)
    result
  end

  # A complete registration through the code; returns the address.
  defp registered(email) do
    %{registration_token: token} = register_request(email)
    {:ok, _credentials} = verify_registration(token, code_from(last_email_to(email)))
    reset_rate_limits()
    email
  end

  defp verify_registration(token, code, ip \\ @ip),
    do: Accounts.verify_email_registration_code(token, code, ip)

  defp verify_sign_in(email, code, ip \\ @ip),
    do: Accounts.verify_email_sign_in_code(email, code, ip)

  defp sign_in_request(email, ip \\ @ip) do
    {:ok, result} = Accounts.request_email_sign_in(email, ip)
    result
  end

  defp wrong(code), do: code |> String.to_integer() |> Kernel.+(1) |> rem(1_000_000) |> pad()
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  defp count(schema), do: Repo.aggregate(schema, :count)

  describe "registration request" do
    test "queues E01 with a code and a fragment link, creates nothing yet" do
      result = register_request("new@example.com")

      assert %{registration_token: "sfg_" <> _, expires_in_seconds: 600, resend_after_seconds: 60} =
               result

      message = last_email_to("new@example.com")
      assert message.subject =~ ~r/\AYour SimpleFit verification code: \d{6}\z/
      assert message.text =~ "https://app.simplefit.example/verify-email#token=sfv_"
      refute message.text =~ "?token="
      refute message.text =~ "/verify-email#token=#{code_from(message)}"
      assert message.text =~ "Expires in 10 minutes"

      assert count(User) == 0
      assert count(Identity) == 0
      assert [%Challenge{purpose: :verification, email: "new@example.com"}] = challenges()
    end

    test "normalizes the address (ADR 0009)" do
      register_request("  New.Person@Example.COM ")
      assert [%Challenge{email: "new.person@example.com"}] = challenges()
      assert [_] = emails_to("new.person@example.com")
    end

    test "rejects malformed addresses with a validation error" do
      for email <- [nil, "", "nope", "a@b", 42] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Accounts.request_email_registration(email, @ip)

        assert Keyword.has_key?(changeset.errors, :email)
      end
    end

    test "a pending registration reserves nothing: it expires or is replaced" do
      register_request("pending@example.com")
      expire_challenges()
      reset_rate_limits()

      # Anyone can start again; the first registration never owned the address.
      %{registration_token: token} = register_request("pending@example.com")

      assert {:ok, _} =
               verify_registration(token, code_from(last_email_to("pending@example.com")))
    end
  end

  describe "registration with the code (same device)" do
    test "creates the user, the email identity and exactly one session" do
      %{registration_token: token} = register_request("fighter@example.com")
      code = code_from(last_email_to("fighter@example.com"))

      assert {:ok, %{access_token: "sfa_" <> _, refresh_token: "sfr_" <> _, session: session}} =
               verify_registration(token, code)

      assert {:ok, user} = Accounts.resolve_user(:email, "fighter@example.com")
      assert session.user_id == user.id
      assert count(Session) == 1

      assert [%Challenge{closed_reason: :code_verified, session_created_at: %DateTime{}}] =
               challenges()

      assert {:ok, :completed} = Accounts.email_registration_status(token, @ip)
    end

    test "replaying the code or token never creates a second user or session" do
      %{registration_token: token} = register_request("fighter@example.com")
      code = code_from(last_email_to("fighter@example.com"))
      assert {:ok, _} = verify_registration(token, code)

      assert {:error, :code_expired} = verify_registration(token, code)
      assert count(User) == 1
      assert count(Session) == 1
    end

    test "a wrong code fails; the fifth exhausts the challenge, even for the right code" do
      %{registration_token: token} = register_request("fighter@example.com")
      code = code_from(last_email_to("fighter@example.com"))

      for _ <- 1..4, do: assert({:error, :code_invalid} = verify_registration(token, wrong(code)))
      assert [%Challenge{failed_attempts: 4, closed_at: nil}] = challenges()

      assert {:error, :code_invalid} = verify_registration(token, wrong(code))
      assert [%Challenge{failed_attempts: 5, closed_reason: :exhausted}] = challenges()

      assert {:error, :code_expired} = verify_registration(token, code)
      assert count(User) == 0
    end

    test "an expired code fails" do
      %{registration_token: token} = register_request("fighter@example.com")
      code = code_from(last_email_to("fighter@example.com"))
      expire_challenges()

      assert {:error, :code_expired} = verify_registration(token, code)
      assert {:ok, :expired} = Accounts.email_registration_status(token, @ip)
    end

    test "unknown or malformed tokens and malformed codes" do
      assert {:error, :code_expired} =
               verify_registration("sfg_" <> String.duplicate("A", 43), "123456")

      assert {:error, :code_expired} = verify_registration("not-a-token", "123456")

      for code <- ["12345", "1234567", "abcdef", nil, 123_456] do
        assert {:error, %Ecto.Changeset{}} = verify_registration("sfg_x", code)
      end
    end

    test "the code is bound to its own registration" do
      %{registration_token: token_a} = register_request("a@example.com")
      %{registration_token: token_b} = register_request("b@example.com")
      code_a = code_from(last_email_to("a@example.com"))

      assert {:error, :code_invalid} = verify_registration(token_b, code_a)
      assert {:ok, _} = verify_registration(token_a, code_a)
    end
  end

  describe "resend" do
    test "supersedes the challenge: new code, link and token; the old ones fail" do
      %{registration_token: old_token} = register_request("fighter@example.com")
      old = last_email_to("fighter@example.com")
      reset_rate_limits()

      %{registration_token: new_token} = register_request("fighter@example.com")
      new = last_email_to("fighter@example.com")

      refute new_token == old_token
      refute link_token_from(new) == link_token_from(old)

      assert [%Challenge{closed_reason: :superseded}, %Challenge{closed_at: nil}] = challenges()

      assert {:error, :code_expired} = verify_registration(old_token, code_from(old))
      assert {:error, :code_expired} = Accounts.verify_email_link(link_token_from(old), @ip)

      assert {:error, :code_invalid} =
               verify_registration(new_token, old_code_unless_equal(old, new))

      assert {:ok, _} = verify_registration(new_token, code_from(new))
    end

    test "is throttled to one request per minute per address" do
      register_request("fighter@example.com")

      assert {:error, {:rate_limited, retry_after}} =
               Accounts.request_email_registration("fighter@example.com", "198.51.100.1")

      assert retry_after in 1..60
    end
  end

  # The old code may collide with the new one (1 in a million); use a wrong
  # code then, so the assertion stays meaningful.
  defp old_code_unless_equal(old, new) do
    if code_from(old) == code_from(new), do: wrong(code_from(new)), else: code_from(old)
  end

  describe "registration with the E01 link (any device, never a session)" do
    test "verifies the email without creating any session" do
      %{registration_token: token} = register_request("fighter@example.com")
      link = link_token_from(last_email_to("fighter@example.com"))

      assert {:ok, :verified} = Accounts.verify_email_link(link, "198.51.100.9")

      assert {:ok, _user} = Accounts.resolve_user(:email, "fighter@example.com")
      assert count(Session) == 0
      assert [%Challenge{closed_reason: :link_verified, session_created_at: nil}] = challenges()

      assert {:ok, :already_verified} = Accounts.verify_email_link(link, @ip)
      assert count(User) == 1
      assert {:ok, :verified_elsewhere} = Accounts.email_registration_status(token, @ip)
    end

    test "Version 66: the registration device cannot get a session from its token afterwards" do
      %{registration_token: token} = register_request("fighter@example.com")
      message = last_email_to("fighter@example.com")
      assert {:ok, :verified} = Accounts.verify_email_link(link_token_from(message), @ip)

      # Even with the right code: the challenge is closed by the link.
      assert {:error, :verified_elsewhere} = verify_registration(token, code_from(message))
      assert count(Session) == 0

      # Fresh proof is an email sign-in (E17), not another E01.
      reset_rate_limits()
      sign_in_request("fighter@example.com")
      e17 = last_email_to("fighter@example.com")
      assert e17.subject =~ "sign-in code"
      assert {:ok, %{session: _}} = verify_sign_in("fighter@example.com", code_from(e17))
      assert count(Session) == 1
    end

    test "code then link, and link then code: one user, one result" do
      %{registration_token: token} = register_request("a@example.com")
      a = last_email_to("a@example.com")
      assert {:ok, _} = verify_registration(token, code_from(a))
      assert {:ok, :already_verified} = Accounts.verify_email_link(link_token_from(a), @ip)

      %{registration_token: token_b} = register_request("b@example.com")
      b = last_email_to("b@example.com")
      assert {:ok, :verified} = Accounts.verify_email_link(link_token_from(b), @ip)
      assert {:error, :verified_elsewhere} = verify_registration(token_b, code_from(b))

      assert count(User) == 2
      assert count(Session) == 1
    end

    test "expired and unknown links" do
      register_request("fighter@example.com")
      link = link_token_from(last_email_to("fighter@example.com"))
      expire_challenges()

      assert {:error, :code_expired} = Accounts.verify_email_link(link, @ip)

      assert {:error, :code_expired} =
               Accounts.verify_email_link("sfv_" <> String.duplicate("A", 43), @ip)

      assert {:error, :code_expired} = Accounts.verify_email_link("whatever", @ip)
      assert {:error, %Ecto.Changeset{}} = Accounts.verify_email_link(nil, @ip)
    end
  end

  describe "an identity that appears during the registration" do
    test "is never linked, moved or merged: the challenge closes as a conflict" do
      %{registration_token: token} = register_request("taken@example.com")
      code = code_from(last_email_to("taken@example.com"))

      {:ok, owner} = Accounts.register_user(:email, "taken@example.com")

      assert {:error, :conflict} = verify_registration(token, code)
      assert {:ok, %{id: owner_id}} = Accounts.resolve_user(:email, "taken@example.com")
      assert owner_id == owner.id
      assert count(User) == 1
      assert count(Session) == 0
      assert [%Challenge{closed_reason: :conflict}] = challenges()
    end

    test "through the link it is already verified, with no session" do
      register_request("taken@example.com")
      link = link_token_from(last_email_to("taken@example.com"))
      {:ok, owner} = Accounts.register_user(:email, "taken@example.com")

      assert {:ok, :already_verified} = Accounts.verify_email_link(link, @ip)
      assert {:ok, %{id: owner_id}} = Accounts.resolve_user(:email, "taken@example.com")
      assert owner_id == owner.id
      assert count(User) == 1
      assert count(Session) == 0
    end
  end

  describe "sign-up with an existing account (never becomes sign-in)" do
    test "answers like a new registration, sends nothing and creates nothing" do
      registered("member@example.com")
      emails_before = length(queued_emails())

      result = register_request("member@example.com")
      assert Map.keys(result) == Map.keys(register_request_shape())
      assert %{registration_token: "sfg_" <> _} = result

      assert length(queued_emails()) == emails_before
      assert count(User) == 1
      assert {:ok, :pending} = Accounts.email_registration_status(result.registration_token, @ip)

      # The decoy matches no code and behaves like a real challenge.
      for _ <- 1..5,
          do:
            assert(
              {:error, :code_invalid} = verify_registration(result.registration_token, "000000")
            )

      assert {:error, :code_expired} = verify_registration(result.registration_token, "000000")
      assert count(Session) == 1
    end
  end

  defp register_request_shape,
    do: %{registration_token: nil, expires_in_seconds: nil, resend_after_seconds: nil}

  describe "sign-in" do
    test "an existing email identity gets E17 (code only) and one session" do
      registered("member@example.com")

      assert %{expires_in_seconds: 600, resend_after_seconds: 60} =
               sign_in_request("member@example.com")

      e17 = last_email_to("member@example.com")
      assert e17.subject =~ ~r/\AYour SimpleFit sign-in code: \d{6}\z/
      refute e17.text =~ "http"
      refute e17.html =~ "<a href"

      assert {:ok, %{session: session}} = verify_sign_in("Member@Example.com", code_from(e17))
      {:ok, user} = Accounts.resolve_user(:email, "member@example.com")
      assert session.user_id == user.id

      assert {:error, :code_expired} = verify_sign_in("member@example.com", code_from(e17))
      assert count(Session) == 2
    end

    test "unknown and pending addresses answer the same and receive nothing" do
      register_request("pending@example.com")
      reset_rate_limits()
      before = length(queued_emails())

      for email <- ["nobody@example.com", "pending@example.com"] do
        assert %{expires_in_seconds: 600, resend_after_seconds: 60} = sign_in_request(email)
      end

      assert length(queued_emails()) == before
    end

    test "verification never reveals whether the account exists" do
      registered("member@example.com")

      # Request, six wrong codes (the fifth exhausts), then a code after expiry.
      outcomes = fn email, code ->
        reset_rate_limits()
        sign_in_request(email)
        attempts = for _ <- 1..6, do: verify_sign_in(email, code)
        reset_rate_limits()
        sign_in_request(email)
        expire_challenges()
        attempts ++ [verify_sign_in(email, code)]
      end

      # Never the real code: derive a wrong one from the next E17.
      member = outcomes.("member@example.com", "000001")
      real_codes = "member@example.com" |> emails_to() |> Enum.map(&code_from/1)

      if "000001" not in real_codes do
        assert member == outcomes.("nobody@example.com", "000001")
        assert Enum.take(member, 5) == List.duplicate({:error, :code_invalid}, 5)
        assert Enum.drop(member, 5) == List.duplicate({:error, :code_expired}, 2)
      end
    end

    test "a sign-in code never satisfies verification, and the other way round" do
      # Verification code used for sign-in.
      register_request("new@example.com")
      e01 = last_email_to("new@example.com")
      sign_in_request("new@example.com")
      assert {:error, :code_invalid} = verify_sign_in("new@example.com", code_from(e01))

      # Sign-in code used for verification.
      registered("member@example.com")
      sign_in_request("member@example.com")
      e17 = last_email_to("member@example.com")
      %{registration_token: decoy} = register_request("member@example.com")
      assert {:error, :code_invalid} = verify_registration(decoy, code_from(e17))
    end

    test "an expired or exhausted sign-in code fails" do
      registered("member@example.com")
      sign_in_request("member@example.com")
      code = code_from(last_email_to("member@example.com"))

      for _ <- 1..5,
          do: assert({:error, :code_invalid} = verify_sign_in("member@example.com", wrong(code)))

      assert {:error, :code_expired} = verify_sign_in("member@example.com", code)

      reset_rate_limits()
      sign_in_request("member@example.com")
      code = code_from(last_email_to("member@example.com"))
      expire_challenges()
      assert {:error, :code_expired} = verify_sign_in("member@example.com", code)
    end

    test "without any request the code is invalid" do
      assert {:error, :code_invalid} = verify_sign_in("nobody@example.com", "123456")
    end
  end

  describe "rate limits" do
    test "per target: the minute window holds whether or not the account exists" do
      registered("member@example.com")

      for email <- ["member@example.com", "nobody@example.com"] do
        assert {:ok, _} = Accounts.request_email_sign_in(email, "198.51.100.1")

        assert {:error, {:rate_limited, _}} =
                 Accounts.request_email_sign_in(email, "198.51.100.2")
      end
    end

    test "per IP: 20 code requests per 10 minutes, across addresses" do
      for n <- 1..20 do
        assert {:ok, _} = Accounts.request_email_sign_in("user#{n}@example.com", "198.51.100.3")
      end

      assert {:error, {:rate_limited, _}} =
               Accounts.request_email_sign_in("user21@example.com", "198.51.100.3")

      assert {:ok, _} = Accounts.request_email_sign_in("user21@example.com", "198.51.100.4")
    end

    test "per IP: 60 code verifications per 10 minutes" do
      for _ <- 1..60,
          do: assert({:error, :code_invalid} = verify_sign_in("x@example.com", "123456"))

      assert {:error, {:rate_limited, _}} = verify_sign_in("x@example.com", "123456")
      assert {:error, :code_invalid} = verify_sign_in("x@example.com", "123456", "198.51.100.5")
    end

    test "nothing personal is stored in rate-limit rows" do
      register_request("private@example.com", "192.0.2.44")
      %{rows: rows} = Repo.query!("SELECT bucket, key_digest FROM auth_rate_limits", [])

      assert rows != []

      for [bucket, digest] <- rows do
        refute bucket =~ "private"
        refute bucket =~ "192.0.2.44"
        assert byte_size(digest) == 32
      end
    end
  end

  describe "stored secrets" do
    test "no code, token, link or raw sign-in address is stored or inspectable" do
      %{registration_token: token} = register_request("fighter@example.com")
      message = last_email_to("fighter@example.com")
      registered("member@example.com")
      sign_in_request("member@example.com")

      dump =
        Repo.query!("SELECT * FROM email_auth_challenges", []).rows
        |> inspect(limit: :infinity, binaries: :as_strings)

      for secret <- [code_from(message), link_token_from(message), token] do
        refute dump =~ secret
      end

      for challenge <- challenges() do
        inspected = inspect(challenge)
        refute inspected =~ "fighter@example.com"
        refute inspected =~ Base.encode16(challenge.code_hash, case: :lower)
      end

      [sign_in] = Enum.filter(challenges(), &(&1.purpose == :sign_in))
      assert sign_in.email == nil
    end
  end

  describe "Secrets" do
    test "codes are six digits and spread over the whole range" do
      codes = for _ <- 1..2_000, do: Secrets.generate_code()
      assert Enum.all?(codes, &Secrets.code?/1)
      assert codes |> Enum.uniq() |> length() > 1_990
      firsts = codes |> Enum.map(&String.first/1) |> Enum.uniq() |> Enum.sort()
      assert firsts == ~w(0 1 2 3 4 5 6 7 8 9)
    end

    test "the code verifier is keyed and bound to the purpose and the challenge" do
      id = Ecto.UUID.generate()
      verifier = Secrets.code_verifier(:verification, id, "123456")

      assert byte_size(verifier) == 32
      assert Secrets.code_matches?(:verification, id, "123456", verifier)
      refute Secrets.code_matches?(:verification, id, "123457", verifier)
      refute Secrets.code_matches?(:verification, Ecto.UUID.generate(), "123456", verifier)
      refute Secrets.code_matches?(:sign_in, id, "123456", verifier)
      refute verifier == :crypto.hash(:sha256, "123456")
      refute Secrets.code_matches?(:verification, id, "123456", Secrets.unmatchable_verifier())
    end

    test "tokens are 32 random bytes with their own prefix, stored as SHA-256" do
      {link, hash} = Secrets.generate_token(:link)
      assert link =~ ~r/\Asfv_[A-Za-z0-9_-]{43}\z/
      assert {:ok, ^hash} = Secrets.parse_token(:link, link)
      assert hash == :crypto.hash(:sha256, link)
      assert :error = Secrets.parse_token(:registration, link)
      {registration, _} = Secrets.generate_token(:registration)
      assert registration =~ ~r/\Asfg_/
    end
  end

  describe "cleanup" do
    test "removes finished challenges after the retention, keeps live ones" do
      register_request("a@example.com")
      register_request("b@example.com")
      expire_challenges()
      reset_rate_limits()
      register_request("c@example.com")

      assert Accounts.EmailAuth.delete_finished_challenges(DateTime.utc_now()) == 2
      assert [%Challenge{email: "c@example.com"}] = challenges()

      assert :ok = perform_cleanup()
    end
  end

  defp perform_cleanup do
    CleanupWorker.perform(%Oban.Job{args: %{}})
  end
end
