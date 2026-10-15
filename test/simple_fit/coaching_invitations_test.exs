defmodule SimpleFit.CoachingInvitationsTest do
  @moduledoc """
  Coach invitations and the fighter's explicit acceptance (SF-57): issuance
  and its prerequisites, tokens, recipient binding, the atomic acceptance
  through SF-56 activation, decline, cancel, expiry, resend, limits and the
  coach data rules.
  """

  # Not async: the sharing configuration is global.
  use SimpleFit.DataCase, async: false
  use Oban.Testing, repo: SimpleFit.Repo

  import ExUnit.CaptureLog

  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.{Accounts, Coaches, Coaching, Fighters}
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaching.{Invitation, InvitationSecrets, Relationship}

  @ip "203.0.113.7"

  setup do
    configure_sharing()
    reset_rate_limits()
    :ok
  end

  defp address, do: "fighter-#{System.unique_integer([:positive])}@example.com"

  defp accept(user, token, version \\ version()) do
    Coaching.accept_invitation(user, %{"token" => token, "disclosure_version" => version}, @ip)
  end

  defp decline(user, token), do: Coaching.decline_invitation(user, %{"token" => token}, @ip)

  defp relationships, do: Repo.aggregate(Relationship, :count)
  defp reload(%Invitation{id: id}), do: Repo.get!(Invitation, id)

  defp expire!(%Invitation{id: id}) do
    past = DateTime.add(DateTime.utc_now(), -60)

    Repo.update_all(from(i in Invitation, where: i.id == ^id), set: [expires_at: past])
  end

  describe "issuing" do
    test "creates only a pending invitation and its E08; no user, profile or relationship" do
      coach = inviting_coach!()
      to = address()
      users = Repo.aggregate(User, :count)

      {invitation, token} = invite!(coach, to, %{"message" => "See you at sparring."})

      assert invitation.status == :pending
      assert invitation.send_count == 1
      assert DateTime.diff(invitation.expires_at, DateTime.utc_now(), :day) in 13..14
      assert Repo.aggregate(User, :count) == users
      assert relationships() == 0
      assert {:error, :not_found} = Accounts.resolve_user(:email, to)

      # The E08: interim truthful copy, the token only in the link fragment.
      email = last_email_to(to)
      assert email.subject == "Coach Marek invited you to connect on SimpleFit"
      assert email.text =~ "https://app.simplefit.example/invite/coach#token=#{token}"
      refute email.text =~ "?token="
      assert email.text =~ "“See you at sparring.” — Coach Marek"

      # Nothing readable is stored: neither the token nor the address.
      row = reload(invitation)
      assert row.token_hash == :crypto.hash(:sha256, token)
      refute inspect(Map.from_struct(row), limit: :infinity) =~ to
      refute inspect(Map.from_struct(row), limit: :infinity) =~ token
      refute row.recipient_sealed =~ to
      assert {:ok, ^to} = InvitationSecrets.open(row.recipient_sealed)
    end

    test "a pending invitation to the same address is returned as is, without a new email" do
      coach = inviting_coach!()
      to = address()
      {first, _token} = invite!(coach, to)

      assert {:ok, again, :existing} =
               Coaching.invite(coach, %{"email" => String.upcase(to)}, @ip)

      assert again.id == first.id
      assert length(emails_to(to)) == 1
    end

    test "requires the gate, a current disclosure and configured, acknowledged data rules" do
      coach = coach_user!()
      params = %{"email" => address()}

      assert {:error, {:conflict, %{data_rules_acknowledgement: "required"}}} =
               Coaching.invite(coach, params, @ip)

      {:ok, _} =
        Coaching.acknowledge_coach_data_rules(coach, %{"document_version" => data_rules_version()})

      assert {:ok, _, :created} = Coaching.invite(coach, params, @ip)

      for opts <- [[enabled: false], [current: nil], [disclosures: %{}], [data_rules: nil]] do
        set_sharing(opts)
        assert {:error, :not_found} = Coaching.invite(coach, %{"email" => address()}, @ip)
        set_sharing([])
      end

      # A new data-rules version must be acknowledged again.
      set_sharing(data_rules: "test-coach-data-rules-v2")

      assert {:error, {:conflict, %{data_rules_acknowledgement: "required"}}} =
               Coaching.invite(coach, %{"email" => address()}, @ip)
    end

    test "requires a completed coach profile" do
      for user <- [registered_user!(), fighter_user!()] do
        assert {:error, :not_found} = Coaching.invite(user, %{"email" => address()}, @ip)
      end
    end

    test "validates the address and the note, and rejects every other field by name" do
      coach = inviting_coach!()

      for {params, field} <- [
            {%{}, :email},
            {%{"email" => "not-an-address"}, :email},
            {%{"email" => address(), "message" => String.duplicate("a", 501)}, :message},
            {%{"email" => address(), "message" => "line\nbreak"}, :message},
            {%{"email" => address(), "coach_profile_id" => Ecto.UUID.generate()},
             "coach_profile_id"},
            {%{"email" => address(), "status" => "accepted"}, "status"},
            {%{"email" => address(), "expires_at" => "2099-01-01"}, "expires_at"}
          ] do
        assert {:error, %Ecto.Changeset{errors: errors}} = Coaching.invite(coach, params, @ip)

        assert List.keymember?(errors, field, 0), inspect(params)
      end

      assert Repo.aggregate(Invitation, :count) == 0
    end

    test "a coach cannot invite an address they hold" do
      {:ok, coach} = Accounts.register_user(:email, "coach-self@example.com")

      coach =
        complete_coach!(
          SimpleFit.AccountRegistrationHelpers.complete_account_registration!(coach)
        )

      {:ok, _} =
        Coaching.acknowledge_coach_data_rules(coach, %{"document_version" => data_rules_version()})

      assert {:error, %Ecto.Changeset{errors: [email: _]}} =
               Coaching.invite(coach, %{"email" => "Coach-Self@Example.com"}, @ip)
    end

    test "at most 50 pending invitations per coach" do
      coach = inviting_coach!()

      for _ <- 1..50 do
        reset_rate_limits()
        invite!(coach, address())
      end

      reset_rate_limits()

      assert {:error, {:conflict, %{pending_invitations: "limit_reached"}}} =
               Coaching.invite(coach, %{"email" => address()}, @ip)
    end

    test "limits per coach, per recipient and per client" do
      coach = inviting_coach!()
      to = address()

      # Per recipient, whatever the coach: 3 a day.
      for name <- ["A", "B", "C"], do: invite!(inviting_coach!("Coach #{name}"), to)

      assert {:error, {:rate_limited, _}} =
               Coaching.invite(inviting_coach!("Coach D"), %{"email" => to}, @ip)

      # Per coach: 10 an hour.
      reset_rate_limits()
      for _ <- 1..10, do: invite!(coach, address())
      assert {:error, {:rate_limited, _}} = Coaching.invite(coach, %{"email" => address()}, @ip)
    end
  end

  describe "accepting" do
    test "a new recipient who signs up with the invited address accepts explicitly" do
      coach = inviting_coach!()
      to = address()
      {invitation, token} = invite!(coach, to)

      fighter = email_fighter!(to)
      assert relationships() == 0

      assert {:ok, %{relationship_id: id, outcome: :created}} = accept(fighter, token)

      relationship = Repo.get!(Relationship, id)
      assert relationship.status == :active
      assert relationship.disclosure_version == version()
      assert relationship.coach_profile_id == Coaches.get_profile(coach).id
      assert relationship.fighter_profile_id == Fighters.get_profile(fighter).id

      accepted = reload(invitation)
      assert accepted.status == :accepted
      assert accepted.accepted_disclosure_version == version()
      assert accepted.relationship_id == id
      assert %DateTime{} = accepted.responded_at

      # A token works once.
      assert {:error, :invitation_unavailable} = accept(fighter, token)
      assert relationships() == 1
    end

    test "only the recipient signed in with the invited address can accept" do
      coach = inviting_coach!()
      to = address()
      {invitation, token} = invite!(coach, to)

      other = email_fighter!(address())
      {:ok, google} = Accounts.register_user(:google, "google-#{System.unique_integer()}")
      google = complete_fighter_onboarding!(google)

      for user <- [other, google] do
        assert {:error, :invitation_recipient_mismatch} = accept(user, token)
        assert {:error, :invitation_recipient_mismatch} = decline(user, token)
      end

      assert reload(invitation).status == :pending
      assert relationships() == 0
      assert {:ok, _} = accept(email_fighter!(to), token)
    end

    test "requires completed account registration, then a fighter profile" do
      to = address()
      {_invitation, token} = invite!(inviting_coach!(), to)
      {:ok, user} = Accounts.register_user(:email, to)

      assert {:error, %Ecto.Changeset{errors: [account_registration: _]}} = accept(user, token)

      SimpleFit.AccountRegistrationHelpers.complete_account_registration!(user)
      assert {:error, %Ecto.Changeset{errors: [fighter_profile: _]}} = accept(user, token)

      complete_fighter_onboarding!(user)
      assert {:ok, %{outcome: :created}} = accept(user, token)
    end

    test "requires exactly the current disclosure version; no other is accepted" do
      to = address()
      {invitation, token} = invite!(inviting_coach!(), to)
      fighter = email_fighter!(to)

      for version <- ["test-disclosure-v0", "fighter-disclosure-v1", "x"] do
        assert {:error, {:conflict, %{disclosure_version: "stale"}}} =
                 accept(fighter, token, version)
      end

      assert {:error, %Ecto.Changeset{errors: [disclosure_version: _]}} =
               Coaching.accept_invitation(fighter, %{"token" => token}, @ip)

      # The current version moves on between preview and acceptance.
      set_sharing(
        disclosures: %{version() => :basic_profile, "test-disclosure-v2" => :basic_profile},
        current: "test-disclosure-v2"
      )

      assert {:error, {:conflict, %{disclosure_version: "stale"}}} = accept(fighter, token)
      assert reload(invitation).status == :pending
      assert {:ok, _} = accept(fighter, token, "test-disclosure-v2")
    end

    test "an already connected pair resolves to the unchanged relationship" do
      coach = inviting_coach!()
      to = address()
      fighter = email_fighter!(to)
      existing = activate!(coach, fighter)

      set_sharing(
        disclosures: %{version() => :basic_profile, "test-disclosure-v2" => :basic_profile},
        current: "test-disclosure-v2"
      )

      {invitation, token} = invite!(coach, to)

      assert {:ok, %{relationship_id: id, outcome: :already_connected}} =
               accept(fighter, token, "test-disclosure-v2")

      assert id == existing.id
      # The earlier disclosure is not widened or replaced.
      assert Repo.get!(Relationship, id).disclosure_version == version()
      assert relationships() == 1

      accepted = reload(invitation)
      assert accepted.status == :accepted
      assert accepted.accepted_disclosure_version == "test-disclosure-v2"
    end

    test "self-coaching is refused at acceptance too, and nothing is consumed" do
      {:ok, both} = Accounts.register_user(:email, "both-roles@example.com")
      both = both |> complete_fighter_onboarding!() |> complete_coach!()
      coach_profile = Coaches.get_profile(both)

      # An invitation to the coach's own address, bypassing the issuing check.
      now = DateTime.utc_now()
      token = InvitationSecrets.generate_token()

      Repo.insert!(%Invitation{
        coach_profile_id: coach_profile.id,
        token_hash: InvitationSecrets.hash!(token),
        recipient_digest: InvitationSecrets.recipient_digest("both-roles@example.com"),
        recipient_sealed: InvitationSecrets.seal("both-roles@example.com"),
        status: :pending,
        expires_at: DateTime.add(now, 3600),
        send_count: 1,
        last_sent_at: now
      })

      assert {:error, :invitation_unavailable} = accept(both, token)
      assert relationships() == 0
      assert Repo.one!(from(i in Invitation, select: i.status)) == :pending
    end

    test "fails closed while sharing is disabled, and stores no consent" do
      to = address()
      {invitation, token} = invite!(inviting_coach!(), to)
      fighter = email_fighter!(to)
      set_sharing(enabled: false)

      assert {:error, :not_found} = accept(fighter, token)
      assert {:error, :not_found} = Coaching.preview_invitation(token, @ip)
      assert reload(invitation).accepted_disclosure_version == nil
      assert relationships() == 0
    end

    test "malformed, unknown and resent tokens are all unavailable" do
      to = address()
      fighter = email_fighter!(to)

      for token <- [
            nil,
            "",
            "sfi_short",
            "sfa_" <> String.duplicate("a", 43),
            42,
            InvitationSecrets.generate_token()
          ] do
        assert {:error, :invitation_unavailable} =
                 Coaching.accept_invitation(
                   fighter,
                   %{"token" => token, "disclosure_version" => version()},
                   @ip
                 )
      end
    end
  end

  describe "declining, cancelling and expiry" do
    test "the recipient declines: nothing is created and the link stops working" do
      to = address()
      {invitation, token} = invite!(inviting_coach!(), to)
      fighter = email_fighter!(to)

      assert :ok = decline(fighter, token)
      assert reload(invitation).status == :declined
      assert {:error, :invitation_unavailable} = accept(fighter, token)
      assert {:error, :invitation_unavailable} = decline(fighter, token)
      assert relationships() == 0
    end

    test "declining needs a completed fighter profile and works while sharing is disabled" do
      to = address()
      {_invitation, token} = invite!(inviting_coach!(), to)
      {:ok, user} = Accounts.register_user(:email, to)
      assert {:error, %Ecto.Changeset{}} = decline(user, token)

      complete_fighter_onboarding!(user)
      set_sharing(enabled: false)
      assert :ok = decline(user, token)
    end

    test "the coach cancels: acceptance is impossible; cancelling again is a no-op" do
      coach = inviting_coach!()
      to = address()
      {invitation, token} = invite!(coach, to)

      assert :ok = Coaching.cancel_invitation(coach, invitation.id)
      assert :ok = Coaching.cancel_invitation(coach, invitation.id)
      assert reload(invitation).status == :cancelled
      assert {:error, :invitation_unavailable} = accept(email_fighter!(to), token)
      assert relationships() == 0
    end

    test "only the issuing coach can cancel or resend; an answered invitation cannot be cancelled" do
      coach = inviting_coach!()
      to = address()
      {invitation, token} = invite!(coach, to)
      other = inviting_coach!("Other")

      assert {:error, :not_found} = Coaching.cancel_invitation(other, invitation.id)
      assert {:error, :not_found} = Coaching.resend_invitation(other, invitation.id, @ip)
      assert {:error, :not_found} = Coaching.cancel_invitation(coach, "nope")

      {:ok, _} = accept(email_fighter!(to), token)
      assert {:error, :conflict} = Coaching.cancel_invitation(coach, invitation.id)
    end

    test "cancelling works while sharing is disabled" do
      coach = inviting_coach!()
      {invitation, _token} = invite!(coach, address())
      set_sharing(enabled: false)
      assert :ok = Coaching.cancel_invitation(coach, invitation.id)
    end

    test "an expired invitation cannot be previewed or accepted, and frees the address" do
      coach = inviting_coach!()
      to = address()
      {invitation, token} = invite!(coach, to)
      fighter = email_fighter!(to)
      expire!(invitation)

      assert {:error, :invitation_unavailable} = Coaching.preview_invitation(token, @ip)
      assert {:error, :invitation_unavailable} = accept(fighter, token)

      {:ok, %{entries: [listed]}} = Coaching.list_invitations(coach, %{})
      assert listed.status == :expired

      # A new invitation to the same address replaces the expired one.
      assert {:ok, fresh, :created} = Coaching.invite(coach, %{"email" => to}, @ip)
      refute fresh.id == invitation.id
      assert reload(invitation).status == :expired
      assert {:error, :invitation_unavailable} = accept(fighter, token)
      assert {:ok, _} = accept(fighter, last_token_to(to))
    end
  end

  describe "resending" do
    defp age!(%Invitation{id: id}, seconds) do
      Repo.update_all(from(i in Invitation, where: i.id == ^id),
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -seconds)]
      )
    end

    test "rotates the token and the expiry: the old link stops working" do
      coach = inviting_coach!()
      to = address()
      {invitation, old} = invite!(coach, to)
      age!(invitation, 61)

      assert {:ok, resent} = Coaching.resend_invitation(coach, invitation.id, @ip)
      assert resent.send_count == 2
      new = last_token_to(to)
      refute new == old
      assert length(emails_to(to)) == 2

      fighter = email_fighter!(to)
      assert {:error, :invitation_unavailable} = accept(fighter, old)
      assert {:ok, _} = accept(fighter, new)
    end

    test "60 seconds apart, at most three times, only while pending" do
      coach = inviting_coach!()
      to = address()
      {invitation, _} = invite!(coach, to)

      assert {:error, {:rate_limited, wait}} =
               Coaching.resend_invitation(coach, invitation.id, @ip)

      assert wait in 1..60

      for _ <- 1..3 do
        age!(invitation, 61)
        assert {:ok, _} = Coaching.resend_invitation(coach, invitation.id, @ip)
      end

      age!(invitation, 61)

      assert {:error, {:conflict, %{resends: "limit_reached"}}} =
               Coaching.resend_invitation(coach, invitation.id, @ip)

      {other, _} = invite!(coach, address())
      :ok = Coaching.cancel_invitation(coach, other.id)
      assert {:error, :conflict} = Coaching.resend_invitation(coach, other.id, @ip)
    end
  end

  describe "preview" do
    test "shows the coach's public identity and the disclosure, nothing about the recipient" do
      coach = inviting_coach!("Coach Marek")
      to = address()
      {_invitation, token} = invite!(coach, to, %{"message" => "Hi"})

      assert {:ok, preview} = Coaching.preview_invitation(token, @ip)
      assert preview.coach == %{display_name: "Coach Marek", brand_name: "Marek Boxing"}
      assert preview.message == "Hi"
      assert preview.disclosure.version == version()
      assert :display_name in preview.disclosure.fields
      assert :weight in preview.disclosure.never_shared
      refute inspect(preview) =~ to
    end
  end

  describe "the coach's list" do
    test "masked addresses, own invitations only, never a token or digest" do
      coach = inviting_coach!()
      {_, token} = invite!(coach, "olga@example.com")
      invite!(inviting_coach!("Other"), address())

      assert {:ok, %{entries: [entry], next_cursor: nil}} = Coaching.list_invitations(coach, %{})
      assert entry.recipient_email == "o•••@example.com"
      assert entry.status == :pending
      assert entry.resends_remaining == 3
      refute inspect(entry) =~ token
      refute Map.has_key?(entry, :token_hash) or Map.has_key?(entry, :recipient_digest)
    end
  end

  describe "coach data rules" do
    test "acknowledges only the configured version, once" do
      coach = coach_user!()

      assert {:ok, %{document_version: v, acknowledged_at: nil}} =
               Coaching.coach_data_rules(coach)

      assert v == data_rules_version()

      assert {:error, {:conflict, %{document_version: "stale"}}} =
               Coaching.acknowledge_coach_data_rules(coach, %{"document_version" => "v0"})

      {:ok, %{acknowledged_at: first}} =
        Coaching.acknowledge_coach_data_rules(coach, %{"document_version" => v})

      {:ok, %{acknowledged_at: again}} =
        Coaching.acknowledge_coach_data_rules(coach, %{"document_version" => v})

      assert first == again

      set_sharing(data_rules: nil)

      assert {:error, :not_found} =
               Coaching.acknowledge_coach_data_rules(coach, %{"document_version" => v})
    end
  end

  describe "E08 delivery" do
    test "the job holds only ciphertext; a provider outage retries without leaking the link" do
      to = "outage-#{System.unique_integer([:positive])}@example.com"
      {invitation, token} = invite!(inviting_coach!(), to)

      [job] = Repo.all(from(j in Oban.Job, where: j.worker == "SimpleFit.Email.DeliveryWorker"))
      raw = Jason.encode!(job.args)
      refute raw =~ token
      refute raw =~ to

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :debug], fn ->
          Process.put(:email_error, :unavailable)
          assert {:error, :unavailable} = perform_job(SimpleFit.Email.DeliveryWorker, job.args)
          Process.put(:email_error, :invalid_request)

          assert {:cancel, :invalid_request} =
                   perform_job(SimpleFit.Email.DeliveryWorker, job.args)

          Process.delete(:email_error)
          assert :ok = perform_job(SimpleFit.Email.DeliveryWorker, job.args)
        end)

      refute log =~ token
      refute log =~ String.slice(token, 4, 20)
      refute log =~ to

      # Delivery is not part of the invitation's state: it stays pending.
      assert reload(invitation).status == :pending
      assert_received {:email_delivered, %{to: [^to]}, _}
    end
  end

  describe "database invariants" do
    test "a resolved invitation is immutable and never pending again" do
      to = address()
      {invitation, token} = invite!(inviting_coach!(), to)
      :ok = decline(email_fighter!(to), token)

      for change <- [[status: :pending, responded_at: nil], [message: "rewritten"]] do
        assert_raise Postgrex.Error, ~r/resolved_immutable/, fn ->
          Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id), set: change)
        end
      end
    end

    test "one pending invitation per coach and recipient; tokens are unique" do
      coach = inviting_coach!()
      {invitation, _} = invite!(coach, address())
      row = reload(invitation)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%{row | id: nil, token_hash: :crypto.strong_rand_bytes(32)})
      end

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%{
          row
          | id: nil,
            recipient_digest: :crypto.strong_rand_bytes(32),
            status: :pending
        })
      end
    end

    test "deleting the fighter keeps the coach's accepted invitation without its relationship" do
      to = address()
      {invitation, token} = invite!(inviting_coach!(), to)
      fighter = email_fighter!(to)
      {:ok, _} = accept(fighter, token)

      Repo.delete!(Repo.get!(User, fighter.id))

      row = reload(invitation)
      assert row.status == :accepted and row.relationship_id == nil
    end
  end
end
