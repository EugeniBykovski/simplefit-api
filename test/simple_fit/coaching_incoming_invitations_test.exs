defmodule SimpleFit.CoachingIncomingInvitationsTest do
  @moduledoc """
  The recipient's invitation inbox (SF-73): matching only through verified
  email identities, the effective SF-57 lifecycle, pagination, the sharing
  gate and the prerequisites. Reading never changes anything.
  """

  # Not async: the sharing configuration is global.
  use SimpleFit.DataCase, async: false

  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.{Accounts, Coaching}
  alias SimpleFit.Coaching.{Invitation, InvitationSecrets, Relationship}

  @ip "203.0.113.7"

  setup do
    configure_sharing()
    reset_rate_limits()
    :ok
  end

  defp address, do: "inbox-#{System.unique_integer([:positive])}@example.com"

  defp inbox(user, params \\ %{}), do: Coaching.list_incoming_invitations(user, params)

  defp ids(user, params \\ %{}) do
    {:ok, %{entries: entries}} = inbox(user, params)
    Enum.map(entries, & &1.invitation_id)
  end

  defp invite_to!(coach, email, attrs \\ %{}) do
    reset_rate_limits()
    invite!(coach, email, attrs)
  end

  # A registered user whose only identity is the verified email `address`.
  defp email_user!(address) do
    {:ok, user} = Accounts.register_user(:email, address)
    SimpleFit.AccountRegistrationHelpers.complete_account_registration!(user)
  end

  defp expire!(%Invitation{id: id}) do
    past = DateTime.add(DateTime.utc_now(), -60)
    Repo.update_all(from(i in Invitation, where: i.id == ^id), set: [expires_at: past])
  end

  describe "verified recipient identity" do
    test "an email identity sees the invitations sent to its address, with the coach's public identity" do
      coach = inviting_coach!("Coach Marek")
      email = address()
      {invitation, _token} = invite_to!(coach, email, %{"message" => "Train with me"})
      user = email_user!(email)

      assert {:ok, %{entries: [entry], next_cursor: nil}} = inbox(user)
      assert entry.invitation_id == invitation.id
      assert entry.status == :pending
      assert entry.coach == %{display_name: "Coach Marek", brand_name: "Marek Boxing"}
      assert entry.message == "Train with me"
      assert entry.responded_at == nil

      assert Map.keys(entry) |> Enum.sort() ==
               ~w(coach created_at expires_at invitation_id message responded_at status)a
    end

    test "a Google or Apple sign-in without an email identity has an empty inbox" do
      coach = inviting_coach!()
      _ = invite_to!(coach, address())
      oauth_only = registered_user!("oauth")

      assert Accounts.verified_email_addresses(oauth_only) == []
      assert {:ok, %{entries: [], next_cursor: nil}} = inbox(oauth_only)
    end

    test "another user's invitations never appear, whatever the request says" do
      coach = inviting_coach!()
      mine = address()
      theirs = address()
      {invitation, _} = invite_to!(coach, mine)
      {other, _} = invite_to!(coach, theirs)
      me = email_user!(mine)
      _them = email_user!(theirs)

      assert ids(me) == [invitation.id]

      # Client-supplied addresses, user ids or digests are not parameters.
      assert ids(me, %{
               "email" => theirs,
               "user_id" => Ecto.UUID.generate(),
               "recipient_digest" => Base.encode64(InvitationSecrets.recipient_digest(theirs))
             }) == [invitation.id]

      refute other.id in ids(me)
    end

    test "several verified email identities see the union of their invitations, once each" do
      coach_a = inviting_coach!("Coach A")
      coach_b = inviting_coach!("Coach B")
      first = address()
      second = address()
      user = email_user!(first)
      {:ok, _} = Accounts.link_identity(user, :email, second)

      {a1, _} = invite_to!(coach_a, first)
      {a2, _} = invite_to!(coach_a, second)
      {b1, _} = invite_to!(coach_b, second)
      {unrelated, _} = invite_to!(coach_b, address())

      listed = ids(user)
      assert Enum.sort(listed) == Enum.sort([a1.id, a2.id, b1.id])
      assert listed == Enum.uniq(listed)
      refute unrelated.id in listed
    end

    test "a Google identity linked to the same user adds nothing; an address claim never counts" do
      coach = inviting_coach!()
      email = address()
      {_invitation, _} = invite_to!(coach, email)
      user = registered_user!("google")
      # A provider-reported email is metadata, never an identity: only a
      # verified email identity can match.
      {:ok, _} =
        Accounts.link_identity(user, :google, "sub-#{System.unique_integer([:positive])}")

      assert ids(user) == []
    end

    test "the dual-role user sees invitations to them, not the ones they sent" do
      coach = inviting_coach!()
      email = address()
      dual = email_user!(email) |> complete_coach!("Dual")

      {:ok, _} =
        Coaching.acknowledge_coach_data_rules(dual, %{"document_version" => data_rules_version()})

      {to_dual, _} = invite_to!(coach, email)
      {sent_by_dual, _} = invite_to!(dual, address())

      assert ids(dual) == [to_dual.id]
      refute sent_by_dual.id in ids(dual)
    end
  end

  describe "lifecycle" do
    test "reports the effective SF-57 status of every outcome and changes nothing" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)

      {pending, _} = invite_to!(coach, email)

      coach_b = inviting_coach!("Coach B")
      {accepted, token_b} = invite_to!(coach_b, email)

      {:ok, _} =
        Coaching.accept_invitation(
          fighter,
          %{"token" => token_b, "disclosure_version" => version()},
          @ip
        )

      coach_c = inviting_coach!("Coach C")
      {declined, token_c} = invite_to!(coach_c, email)
      :ok = Coaching.decline_invitation(fighter, %{"token" => token_c}, @ip)

      coach_d = inviting_coach!("Coach D")
      {cancelled, _} = invite_to!(coach_d, email)
      :ok = Coaching.cancel_invitation(coach_d, cancelled.id)

      coach_e = inviting_coach!("Coach E")
      {expired, _} = invite_to!(coach_e, email)
      expire!(expired)

      before = Repo.all(from(i in Invitation, order_by: i.id))
      relationships = Repo.aggregate(Relationship, :count)

      {:ok, %{entries: entries}} = inbox(fighter)
      statuses = Map.new(entries, &{&1.invitation_id, &1.status})

      assert statuses == %{
               pending.id => :pending,
               accepted.id => :accepted,
               declined.id => :declined,
               cancelled.id => :cancelled,
               expired.id => :expired
             }

      for entry <- entries, entry.status in [:accepted, :declined, :cancelled] do
        assert %DateTime{} = entry.responded_at
      end

      # Reading resolves nothing: the expired row is still stored as pending.
      assert Repo.all(from(i in Invitation, order_by: i.id)) == before
      assert Repo.aggregate(Relationship, :count) == relationships
      assert Repo.get!(Invitation, expired.id).status == :pending
    end

    test "the status filter uses the effective status: never both pending and expired" do
      coach = inviting_coach!()
      email = address()
      user = email_user!(email)
      {live, _} = invite_to!(coach, email)
      coach_b = inviting_coach!("Coach B")
      {lapsed, _} = invite_to!(coach_b, email)
      expire!(lapsed)

      assert ids(user, %{"status" => "pending"}) == [live.id]
      assert ids(user, %{"status" => "expired"}) == [lapsed.id]
      assert ids(user, %{"status" => "accepted"}) == []
    end

    test "a resend keeps one entry with the new expiry" do
      coach = inviting_coach!()
      email = address()
      user = email_user!(email)
      {invitation, _} = invite_to!(coach, email)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -120)]
      )

      {:ok, resent} = Coaching.resend_invitation(coach, invitation.id, @ip)

      assert {:ok, %{entries: [entry]}} = inbox(user)
      assert entry.invitation_id == invitation.id
      assert entry.expires_at == resent.expires_at
    end

    test "a deleted coach's invitations disappear with the coach (no orphan entry)" do
      coach = inviting_coach!()
      email = address()
      user = email_user!(email)
      {_invitation, _} = invite_to!(coach, email)

      Repo.delete_all(from(u in SimpleFit.Accounts.User, where: u.id == ^coach.id))

      assert ids(user) == []
    end
  end

  describe "pagination" do
    # Rows with identical creation times, inserted directly (as expired, so
    # the one-pending-per-coach index allows several), to prove the
    # tie-breaker; the inbox only reads.
    defp seed!(email, count, at) do
      coach_profile_id = SimpleFit.Coaches.get_profile(inviting_coach!()).id
      digest = InvitationSecrets.recipient_digest(email)

      rows =
        for _ <- 1..count do
          %{
            id: Ecto.UUID.generate(),
            coach_profile_id: coach_profile_id,
            token_hash: InvitationSecrets.hash!(InvitationSecrets.generate_token()),
            recipient_digest: digest,
            recipient_sealed: InvitationSecrets.seal(email),
            status: :expired,
            expires_at: at,
            send_count: 1,
            last_sent_at: at,
            inserted_at: at,
            updated_at: at
          }
        end

      Repo.insert_all(Invitation, rows)
      Enum.map(rows, & &1.id)
    end

    test "keyset pages are stable, complete and free of duplicates, also on equal timestamps" do
      email = address()
      user = email_user!(email)
      at = DateTime.utc_now()
      seeded = seed!(email, 7, at) ++ seed!(email, 4, DateTime.add(at, -10))

      pages =
        Stream.unfold(nil, fn
          :done ->
            nil

          cursor ->
            {:ok, page} = inbox(user, %{"limit" => "3", "cursor" => cursor})
            {page.entries, page.next_cursor || :done}
        end)
        |> Enum.to_list()

      listed = pages |> List.flatten() |> Enum.map(& &1.invitation_id)
      assert length(pages) == 4
      assert Enum.sort(listed) == Enum.sort(seeded)
      assert listed == Enum.uniq(listed)

      order = pages |> List.flatten() |> Enum.map(&{&1.created_at, &1.invitation_id})
      assert order == Enum.sort(order, :desc)
    end

    test "a cursor never widens access: another user's position only seeks within the caller's own rows" do
      mine = address()
      theirs = address()
      me = email_user!(mine)
      them = email_user!(theirs)
      _ = seed!(theirs, 3, DateTime.utc_now())
      my_ids = seed!(mine, 2, DateTime.add(DateTime.utc_now(), -100))

      {:ok, %{next_cursor: their_cursor}} = inbox(them, %{"limit" => "1"})
      listed = ids(me, %{"cursor" => their_cursor})

      assert Enum.sort(listed) == Enum.sort(my_ids)
    end

    test "invalid limits, cursors and statuses are validation errors" do
      user = email_user!(address())

      for params <- [
            %{"limit" => "0"},
            %{"limit" => "101"},
            %{"limit" => "ten"},
            %{"cursor" => "not-a-cursor"},
            %{"cursor" => Base.url_encode64("123|not-a-uuid", padding: false)},
            %{"status" => "active"},
            %{"status" => ["pending"]}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} = inbox(user, params)
      end
    end
  end

  describe "gate and prerequisites" do
    test "with sharing disabled the inbox is unavailable, not empty" do
      coach = inviting_coach!()
      email = address()
      {_invitation, _} = invite_to!(coach, email)
      user = email_user!(email)

      set_sharing(enabled: false)
      assert inbox(user) == {:error, :not_found}

      set_sharing(enabled: true, disclosures: %{}, current: nil)
      assert {:ok, %{entries: [_]}} = inbox(user)
    end

    test "account registration must be complete; a fighter profile is not required to read" do
      coach = inviting_coach!()
      email = address()
      {invitation, _} = invite_to!(coach, email)
      {:ok, unregistered} = Accounts.register_user(:email, email)

      assert {:error, %Ecto.Changeset{errors: [account_registration: _]}} = inbox(unregistered)

      registered =
        SimpleFit.AccountRegistrationHelpers.complete_account_registration!(unregistered)

      assert SimpleFit.Fighters.get_profile(registered) == nil
      assert ids(registered) == [invitation.id]

      complete_fighter_onboarding!(registered)
      assert ids(registered) == [invitation.id]
    end
  end
end
