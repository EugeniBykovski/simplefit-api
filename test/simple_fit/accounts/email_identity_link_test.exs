defmodule SimpleFit.Accounts.EmailIdentityLinkTest do
  @moduledoc """
  Verified email identity linking (SF-77, ADR 0024): a signed-in user proves
  control of an address with a code entered in the same session, and the
  address becomes an email identity of that same user. Never a new user, a
  merge, a transfer or a session.
  """

  # Not async: the privacy test raises the global log level to debug.
  use SimpleFit.DataCase, async: false

  import ExUnit.CaptureLog
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.EmailAuth.{Challenge, CleanupWorker}
  alias SimpleFit.Accounts.{Identity, Session, Sessions, User}

  @ip "203.0.113.77"

  # A user signed in through `provider` and the session of that sign-in.
  defp signed_in(provider \\ :google) do
    subject =
      case provider do
        :email -> "member-#{System.unique_integer([:positive])}@example.com"
        _oauth -> "#{provider}-subject-#{System.unique_integer([:positive])}"
      end

    {:ok, user} = Accounts.register_user(provider, subject)
    session_of(user)
  end

  defp session_of(user) do
    {:ok, credentials} = Accounts.create_session(user)
    {:ok, viewer} = Accounts.authenticate_access_token(credentials.access_token)
    Map.put(viewer, :access_token, credentials.access_token)
  end

  defp address, do: "link-#{System.unique_integer([:positive])}@example.com"

  defp request(%{user: user, session: session}, email, ip \\ @ip),
    do: Accounts.request_email_identity_link(user, session, email, ip)

  defp confirm(%{user: user, session: session}, email, code, ip \\ @ip),
    do: Accounts.confirm_email_identity_link(user, session, email, code, ip)

  # Requests a code for `email` and returns it from the queued email.
  defp code_for(viewer, email) do
    reset_rate_limits()
    assert {:ok, %{expires_in_seconds: 600, resend_after_seconds: 60}} = request(viewer, email)
    code_from(last_email_to(email))
  end

  defp wrong(code), do: code |> String.to_integer() |> Kernel.+(1) |> rem(1_000_000) |> pad()
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  defp count(schema), do: Repo.aggregate(schema, :count)

  # Every identity as {user_id, provider, subject}: the identity graph.
  defp graph do
    Identity
    |> Repo.all()
    |> Enum.map(&{&1.user_id, &1.provider, &1.provider_subject})
    |> Enum.sort()
  end

  defp link_challenges, do: Enum.filter(challenges(), &(&1.purpose == :identity_link))

  describe "linking a new address" do
    test "A: a Google-only user adds a verified email identity to the same user" do
      viewer = signed_in(:google)
      email = address()
      [google] = Repo.all(Identity)
      users = count(User)
      sessions = count(Session)

      code = code_for(viewer, email)

      assert {:ok, %{outcome: :linked, identity: identity}} = confirm(viewer, email, code)
      assert %Identity{provider: :email, provider_subject: ^email} = identity
      assert identity.user_id == viewer.user.id

      assert Accounts.verified_email_addresses(viewer.user) == [email]
      assert [%{email: ^email}] = Accounts.list_email_identities(viewer.user)
      # The Google identity is untouched; nothing else was created.
      assert Repo.get!(Identity, google.id) == google
      assert count(User) == users
      assert count(Session) == sessions

      assert [%Challenge{closed_reason: :code_verified, session_created_at: nil}] =
               link_challenges()
    end

    test "B: an Apple-only user adds a verified email identity to the same user" do
      viewer = signed_in(:apple)
      email = address()

      code = code_for(viewer, email)

      assert {:ok, %{outcome: :linked}} = confirm(viewer, email, code)

      assert viewer.user.id
             |> then(&Repo.all(from(i in Identity, where: i.user_id == ^&1, select: i.provider)))
             |> Enum.sort() == [:apple, :email]

      assert count(User) == 1
    end

    test "the address is normalized like every email identity (ADR 0009)" do
      viewer = signed_in()
      assert {:ok, _} = request(viewer, "  Fighter.One+Box@Example.COM ")
      code = code_from(last_email_to("fighter.one+box@example.com"))

      assert [%Challenge{email: "fighter.one+box@example.com"}] = link_challenges()

      assert {:ok, %{identity: %{provider_subject: "fighter.one+box@example.com"}}} =
               confirm(viewer, "FIGHTER.ONE+BOX@example.com", code)

      # Dots and +tags are kept: a different address is a different identity.
      refute "fighterone@example.com" in Accounts.verified_email_addresses(viewer.user)
    end

    test "the email states its purpose and carries no token or link" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)
      message = last_email_to(email)

      assert message.subject == "Your SimpleFit email verification code: #{code}"
      assert message.text =~ "add this email address to it"
      assert message.text =~ "Expires in 10 minutes"
      assert message.text =~ "Without the code, the address isn’t added to any account."
      refute message.text =~ ~r/sf[agrvi]_/
      refute message.text =~ "http"
      refute message.text =~ viewer.user.id
    end
  end

  describe "addresses that already have an identity" do
    test "C: the user's own address is idempotent: nothing is duplicated" do
      viewer = signed_in(:email)
      [%Identity{provider_subject: email} = existing] = Repo.all(Identity)
      before = graph()

      code = code_for(viewer, email)

      assert {:ok, %{outcome: :already_linked, identity: ^existing}} =
               confirm(viewer, email, code)

      assert graph() == before
    end

    test "D: another user's address: the same request answer, and a conflict only after proof" do
      owner = signed_in(:email)
      [%Identity{provider_subject: taken}] = Repo.all(Identity)
      viewer = signed_in(:google)
      before = graph()

      fresh = address()
      reset_rate_limits()
      assert {:ok, answer_fresh} = request(viewer, fresh)
      reset_rate_limits()
      assert {:ok, answer_taken} = request(viewer, taken)
      assert answer_fresh == answer_taken

      code = code_from(last_email_to(taken))
      # Without the code nothing about the owner is revealed.
      assert confirm(viewer, taken, wrong(code)) == {:error, :code_invalid}

      assert confirm(viewer, taken, code) == {:error, :conflict}
      assert graph() == before
      assert Accounts.verified_email_addresses(owner.user) == [taken]
      assert Accounts.verified_email_addresses(viewer.user) == []
      assert List.last(link_challenges()).closed_reason == :conflict
    end
  end

  describe "codes" do
    test "F: a wrong code links nothing and counts" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)
      before = graph()

      assert confirm(viewer, email, wrong(code)) == {:error, :code_invalid}
      assert graph() == before
      assert [%Challenge{failed_attempts: 1, closed_at: nil}] = link_challenges()
    end

    test "a code for another address counts as a wrong code" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)

      assert confirm(viewer, address(), code) == {:error, :code_invalid}
      assert [%Challenge{failed_attempts: 1}] = link_challenges()
      assert {:ok, %{outcome: :linked}} = confirm(viewer, email, code)
    end

    test "G: an expired code links nothing" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)
      expire_challenges()

      assert confirm(viewer, email, code) == {:error, :code_expired}
      assert Accounts.verified_email_addresses(viewer.user) == []
    end

    test "H: a used code cannot be replayed" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)

      assert {:ok, %{outcome: :linked}} = confirm(viewer, email, code)
      assert confirm(viewer, email, code) == {:error, :code_expired}
      assert count(Identity) == 2
    end

    test "I: the fifth wrong code closes the challenge; the right one is refused after" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)

      for _ <- 1..5, do: assert(confirm(viewer, email, wrong(code)) == {:error, :code_invalid})

      assert [%Challenge{closed_reason: :exhausted, failed_attempts: 5}] = link_challenges()
      assert confirm(viewer, email, code) == {:error, :code_expired}
      assert Accounts.verified_email_addresses(viewer.user) == []
    end

    test "a new request supersedes the previous code, for any address" do
      viewer = signed_in()
      first = address()
      first_code = code_for(viewer, first)
      second = address()
      second_code = code_for(viewer, second)

      assert [%Challenge{closed_reason: :superseded}, %Challenge{closed_at: nil}] =
               link_challenges()

      assert {:error, _} = confirm(viewer, first, first_code)
      assert {:ok, %{outcome: :linked}} = confirm(viewer, second, second_code)
      assert Accounts.verified_email_addresses(viewer.user) == [second]
    end

    test "requesting again does not restore spent attempts beyond the request limits" do
      viewer = signed_in()
      email = address()
      _code = code_for(viewer, email)

      # Per user, whatever the address: 1 per minute, 5 per hour, 10 per day.
      assert {:error, {:rate_limited, _}} = request(viewer, address())
      assert {:error, {:rate_limited, _}} = request(viewer, email)

      # Another session of the same user shares the user's limits.
      other_session = session_of(viewer.user)
      assert {:error, {:rate_limited, _}} = request(other_session, address())
      assert length(link_challenges()) == 1
    end

    test "the per-user windows hold across addresses and sessions within a day" do
      viewer = signed_in()

      results =
        for n <- 1..12 do
          # Only the one-minute window is reset: the hour and day windows keep counting.
          Repo.query!("DELETE FROM auth_rate_limits WHERE bucket LIKE '%:minute'", [])

          request(
            session_of(viewer.user),
            "rotate-#{n}-#{System.unique_integer([:positive])}@example.com"
          )
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == 5
      assert Enum.all?(Enum.drop(results, 5), &match?({:error, {:rate_limited, _}}, &1))
    end

    test "the per-address windows hold across users" do
      email = address()
      assert {:ok, _} = request(signed_in(), email)
      assert {:error, {:rate_limited, _}} = request(signed_in(), email)
    end

    test "malformed input is a validation error and changes nothing" do
      viewer = signed_in()

      for email <- [nil, "", "not-an-email", "a@b", 42, %{"x" => 1}, "üser@example.com"] do
        assert {:error, %Ecto.Changeset{}} = request(viewer, email)
      end

      for code <- [nil, "12345", "1234567", "abcdef", 123_456] do
        assert {:error, %Ecto.Changeset{}} = confirm(viewer, address(), code)
      end

      assert link_challenges() == []
      assert queued_emails() == []
    end
  end

  describe "session and user binding" do
    test "J: a code cannot be confirmed after the session was logged out or revoked" do
      for revoke <- [:logout, :refresh_reuse] do
        viewer = signed_in()
        email = address()
        code = code_for(viewer, email)

        case revoke do
          :logout -> Accounts.revoke_session({:access, viewer.access_token})
          :refresh_reuse -> Sessions.revoke_session(viewer.session.id, revoke)
        end

        assert confirm(viewer, email, code) == {:error, :unauthorized}
        assert Accounts.verified_email_addresses(viewer.user) == []
        assert List.last(link_challenges()).closed_at == nil
      end
    end

    test "an expired session cannot confirm" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)

      Repo.update_all(from(s in Session, where: s.id == ^viewer.session.id),
        set: [
          inserted_at: DateTime.add(DateTime.utc_now(:second), -7200),
          expires_at: DateTime.add(DateTime.utc_now(:second), -1)
        ]
      )

      assert confirm(viewer, email, code) == {:error, :unauthorized}
      assert Accounts.verified_email_addresses(viewer.user) == []
    end

    test "K: user A's challenge cannot be completed by user B" do
      alice = signed_in()
      bob = signed_in()
      email = address()
      code = code_for(alice, email)

      assert confirm(bob, email, code) == {:error, :code_expired}
      # A session presented with another user's struct is refused, too.
      assert confirm(%{bob | user: alice.user}, email, code) == {:error, :unauthorized}

      assert [%Challenge{failed_attempts: 0, closed_at: nil}] = link_challenges()
      assert Accounts.verified_email_addresses(bob.user) == []
      assert {:ok, %{outcome: :linked}} = confirm(alice, email, code)
    end

    test "a code requested in one session is not accepted in another session of the same user" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)
      other = session_of(viewer.user)

      assert confirm(other, email, code) == {:error, :code_expired}
      assert [%Challenge{failed_attempts: 0}] = link_challenges()
      assert {:ok, _} = confirm(viewer, email, code)
    end

    test "deleting the user removes its link challenges; a stale caller is refused" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)

      Repo.delete!(viewer.user)

      assert link_challenges() == []
      assert confirm(viewer, email, code) == {:error, :unauthorized}
      assert count(Identity) == 0
      assert count(User) == 0
    end

    test "a request for a deleted session or user is refused and stores nothing" do
      viewer = signed_in()
      Repo.delete!(viewer.user)

      assert request(viewer, address()) == {:error, :unauthorized}
      assert challenges() == []
      assert queued_emails() == []
    end
  end

  describe "purpose separation" do
    test "a link code never signs in, verifies a registration or creates a session" do
      viewer = signed_in()
      email = address()
      code = code_for(viewer, email)
      sessions = count(Session)

      assert Accounts.verify_email_sign_in_code(email, code, @ip) == {:error, :code_invalid}
      assert count(Session) == sessions
      assert {:ok, _} = confirm(viewer, email, code)
    end

    test "a sign-in code never confirms a link" do
      member = signed_in(:email)
      [%Identity{provider_subject: email}] = Repo.all(Identity)
      viewer = signed_in(:google)
      _link_code = code_for(viewer, email)

      reset_rate_limits()
      {:ok, _} = Accounts.request_email_sign_in(email, @ip)
      sign_in_code = code_from(last_email_to(email))

      assert {:error, _} = confirm(viewer, email, sign_in_code)
      assert Accounts.verified_email_addresses(member.user) == [email]
      assert Accounts.verified_email_addresses(viewer.user) == []
    end

    test "Q: a linked address signs in to the same user with the unchanged email sign-in" do
      viewer = signed_in(:google)
      email = address()
      {:ok, _} = confirm(viewer, email, code_for(viewer, email))

      reset_rate_limits()
      {:ok, _} = Accounts.request_email_sign_in(email, @ip)
      code = code_from(last_email_to(email))

      assert {:ok, %{session: %Session{user_id: user_id}}} =
               Accounts.verify_email_sign_in_code(email, code, @ip)

      assert user_id == viewer.user.id
      assert count(User) == 1
    end

    test "registration for a linked address creates nothing (decoy, ADR 0012)" do
      viewer = signed_in(:google)
      email = address()
      {:ok, _} = confirm(viewer, email, code_for(viewer, email))
      emails = length(queued_emails())

      reset_rate_limits()
      assert {:ok, %{registration_token: _}} = Accounts.request_email_registration(email, @ip)
      assert length(queued_emails()) == emails
    end
  end

  describe "privacy" do
    test "P: no code, address or user id in logs, jobs or telemetry" do
      viewer = signed_in()
      email = address()
      parent = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        id,
        for(
          e <- [:requested, :sent, :verified, :rejected, :rate_limited],
          do: [:simple_fit, :auth, :email, e]
        ),
        fn event, _measurements, metadata, _ -> send(parent, {:event, event, metadata}) end,
        nil
      )

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :debug], fn ->
          {:ok, _} = request(viewer, email)
          code = code_from(last_email_to(email))
          {:error, :code_invalid} = confirm(viewer, email, wrong(code))
          {:ok, _} = confirm(viewer, email, code)
          {:error, {:rate_limited, _}} = request(viewer, email)
          send(parent, {:code, code})
        end)

      Logger.configure(level: level)
      :telemetry.detach(id)
      assert_received {:code, code}

      for secret <- [code, email, viewer.user.id] do
        refute log =~ secret
      end

      [job] = Repo.all(Oban.Job)
      refute inspect(job, limit: :infinity) =~ code
      refute inspect(job, limit: :infinity) =~ email

      events = collect_events([])

      assert {[:simple_fit, :auth, :email, :verified],
              %{channel: :code, outcome: :linked, purpose: :identity_link}} in events

      assert {[:simple_fit, :auth, :email, :rejected],
              %{reason: :code_invalid, purpose: :identity_link}} in events

      assert {[:simple_fit, :auth, :email, :requested],
              %{outcome: :accepted, purpose: :identity_link}} in events

      assert {[:simple_fit, :auth, :email, :rate_limited], %{}} in events

      for {_event, metadata} <- events, secret <- [code, email, viewer.user.id] do
        refute inspect(metadata) =~ secret
      end

      # The challenge is redacted from inspect.
      [challenge] = link_challenges()
      refute inspect(challenge) =~ email
    end

    test "finished link challenges are cleaned up like every challenge" do
      viewer = signed_in()
      email = address()
      {:ok, _} = confirm(viewer, email, code_for(viewer, email))
      Repo.update_all(Challenge, set: [closed_at: DateTime.add(DateTime.utc_now(), -7200)])

      assert :ok = perform_job(CleanupWorker, %{})
      assert link_challenges() == []
      assert email in Accounts.verified_email_addresses(viewer.user)
    end
  end

  defp collect_events(acc) do
    receive do
      {:event, event, metadata} -> collect_events([{event, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
