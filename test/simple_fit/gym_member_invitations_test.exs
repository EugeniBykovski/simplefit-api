defmodule SimpleFit.GymMemberInvitationsTest do
  @moduledoc """
  Gym member invitations (E07, SF-95): creation and its E07 email through
  the outbox, recipient binding to a verified email identity, acceptance by
  inbox id and by token, decline, expiry (7 days), resend, cancel, the
  approval of a pending request by acceptance, separation from staff
  invitations, audit events and what is never stored or shown.
  """

  use SimpleFit.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers

  alias SimpleFit.{EmailAuthHelpers, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, Member, MemberInvitation, MemberInvitations}

  setup do
    owner = registered_as!(registered!("member-inv"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym}
  end

  defp accept(user, locator),
    do: Gyms.accept_member_invitation(user, live_session!(user), locator, client_ip())

  defp events(gym_id, type),
    do: Repo.all(from(e in AuditEvent, where: e.gym_id == ^gym_id and e.event_type == ^type))

  describe "inviting" do
    test "creates a pending invitation and queues E07; the same address again is the same", ctx do
      email = address("invitee")

      assert {:ok, view, :created} =
               Gyms.create_member_invitation(
                 ctx.owner,
                 ctx.gym.id,
                 %{"email" => email},
                 client_ip()
               )

      assert %{status: :pending, resends_remaining: 3, gym_member_id: nil} = view
      assert view.recipient_email =~ ~r/^i•••@example\.com$/
      assert view.invited_by.name == "Yauheni B."
      assert DateTime.diff(view.expires_at, view.created_at) == MemberInvitations.lifetime()

      message = EmailAuthHelpers.last_email_to(email)
      assert message.subject == "Simple Boxing Gym invited you to join on SimpleFit"
      assert message.text =~ "the gym used your email address to invite you"
      refute message.text =~ "plan"
      token = member_token_for(email)
      assert String.starts_with?(token, "sgm_")

      stored = Repo.get!(MemberInvitation, view.invitation_id)
      refute stored.recipient_sealed =~ email
      refute inspect(stored) =~ email
      refute inspect(stored) =~ token

      assert {:ok, same, :existing} =
               Gyms.create_member_invitation(
                 ctx.owner,
                 ctx.gym.id,
                 %{"email" => String.upcase(email)},
                 client_ip()
               )

      assert same.invitation_id == view.invitation_id
      assert [_one] = events(ctx.gym.id, :member_invited)
    end

    test "owner, manager and front desk invite; coaches and outsiders cannot", ctx do
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk)
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)

      assert {:ok, _, :created} =
               Gyms.create_member_invitation(
                 desk,
                 ctx.gym.id,
                 %{"email" => address()},
                 client_ip()
               )

      assert {:error, :forbidden} =
               Gyms.create_member_invitation(
                 coach,
                 ctx.gym.id,
                 %{"email" => address()},
                 client_ip()
               )

      assert {:error, :forbidden} = Gyms.list_member_invitations(coach, ctx.gym.id, %{})

      assert {:error, :not_found} =
               Gyms.create_member_invitation(
                 registered!("o"),
                 ctx.gym.id,
                 %{"email" => address()},
                 client_ip()
               )
    end

    test "invalid input, drafts and active members are refused", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Gyms.create_member_invitation(
                 ctx.owner,
                 ctx.gym.id,
                 %{"email" => "nope"},
                 client_ip()
               )

      assert {:error, %Ecto.Changeset{} = changeset} =
               Gyms.create_member_invitation(
                 ctx.owner,
                 ctx.gym.id,
                 %{"email" => address(), "plan" => "Unlimited"},
                 client_ip()
               )

      assert Enum.any?(changeset.errors, fn {field, _} -> field == "plan" end)

      draft_owner = registered!("draft-inv")
      draft = draft_gym!(draft_owner)

      assert {:error, {:conflict, %{setup_status: "draft"}}} =
               Gyms.create_member_invitation(
                 draft_owner,
                 draft.id,
                 %{"email" => address()},
                 client_ip()
               )

      code = join_code!(ctx.owner, ctx.gym.id)
      {member, _} = active_member!(ctx.owner, ctx.gym.id, code)
      [email] = SimpleFit.Accounts.verified_email_addresses(member)

      assert {:error, {:conflict, %{gym_member: "already_active"}}} =
               Gyms.create_member_invitation(
                 ctx.owner,
                 ctx.gym.id,
                 %{"email" => email},
                 client_ip()
               )
    end

    test "3 invitations per day per address, across gyms", ctx do
      email = address("popular")

      for _ <- 1..3 do
        owner = registered!("gym-owner")
        gym = completed_gym!(owner)
        invite_member!(owner, gym.id, email)
      end

      assert {:error, {:rate_limited, _}} =
               Gyms.create_member_invitation(
                 ctx.owner,
                 ctx.gym.id,
                 %{"email" => email},
                 client_ip()
               )
    end
  end

  describe "accepting" do
    test "from the inbox: an active membership, the invitation consumed, audited", ctx do
      email = address("inbox")
      user = email_user!(email, "Marta Kowalska")
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)

      assert {:ok, %{entries: [entry]}} = Gyms.list_my_member_invitations(user, %{})
      assert entry.sent_to == email
      assert entry.invited_by == %{first_name: "Yauheni", role: :owner}

      assert {:ok, result} = accept(user, {:id, invitation.invitation_id})
      assert result.outcome == :accepted
      assert result.invitation.status == :accepted

      assert %Member{status: :active, joined_via: :invitation, user_id: user_id} =
               stored_member(result.gym_member_id)

      assert user_id == user.id

      assert {:ok, again} = accept(user, {:id, invitation.invitation_id})
      assert again.outcome == :already_accepted
      assert again.gym_member_id == result.gym_member_id

      assert [_] = events(ctx.gym.id, :member_invitation_accepted)

      # No staff access, no workspace.
      assert {:error, :not_found} = Gyms.get_gym(user, ctx.gym.id)
    end

    test "by token from the web link; a token held by someone else is a mismatch", ctx do
      email = address("token")
      user = email_user!(email)
      invite_member!(ctx.owner, ctx.gym.id, email)
      token = member_token_for(email)

      assert {:ok, preview} = Gyms.preview_member_invitation(token, client_ip())
      assert preview.gym.name == "Simple Boxing Gym"
      refute inspect(preview) =~ email

      stranger = email_user!(address("stranger"))
      assert {:error, :invitation_recipient_mismatch} = accept(stranger, {:token, token})

      assert {:error, :not_found} =
               Gyms.get_my_member_invitation(
                 stranger,
                 Repo.one!(
                   from(i in MemberInvitation, select: i.id, where: i.gym_id == ^ctx.gym.id)
                 )
               )

      assert {:ok, %{outcome: :accepted}} = accept(user, {:token, token})

      assert {:error, :invitation_unavailable} =
               Gyms.preview_member_invitation(token, client_ip())
    end

    test "a Google/Apple account without the email identity cannot accept; linking it first works",
         ctx do
      email = address("linked")

      {:ok, google_user} =
        SimpleFit.Accounts.register_user(
          :google,
          "google-sub-#{System.unique_integer([:positive])}"
        )

      google_user = registered_as!(google_user, "Ola Nowak")
      invite_member!(ctx.owner, ctx.gym.id, email)
      token = member_token_for(email)

      assert {:error, :invitation_recipient_mismatch} = accept(google_user, {:token, token})
      link_email!(google_user, email)
      assert {:ok, %{outcome: :accepted}} = accept(google_user, {:token, token})
    end

    test "unknown, malformed, expired and cancelled tokens all answer unavailable", ctx do
      email = address("gone")
      user = email_user!(email)
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)
      token = member_token_for(email)

      assert {:error, :invitation_unavailable} = accept(user, {:token, "sgm_nope"})
      assert {:error, :invitation_unavailable} = accept(user, {:token, nil})
      # A staff token never matches a member invitation.
      assert {:error, :invitation_unavailable} =
               accept(user, {:token, "sfs_" <> String.duplicate("A", 43)})

      Repo.update_all(from(i in MemberInvitation, where: i.id == ^invitation.invitation_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert {:error, :invitation_unavailable} = accept(user, {:token, token})
      assert {:error, :invitation_unavailable} = accept(user, {:id, invitation.invitation_id})
      assert {:ok, %{entries: [%{status: :expired}]}} = Gyms.list_my_member_invitations(user, %{})
      assert member_rows(ctx.gym.id, user) == []
    end

    test "acceptance approves the recipient's pending join request", ctx do
      code = join_code!(ctx.owner, ctx.gym.id)
      email = address("pending")
      user = email_user!(email)
      {:ok, request, :created} = join(user, code)
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)

      assert {:ok, %{gym_member_id: id}} = accept(user, {:id, invitation.invitation_id})
      assert id == request.gym_member_id
      assert %Member{status: :active, joined_via: :join_code} = stored_member(id)
      assert [_] = events(ctx.gym.id, :member_join_approved)
    end

    test "an already active member cannot accept; the invitation stays pending", ctx do
      code = join_code!(ctx.owner, ctx.gym.id)
      email = address("active")
      user = email_user!(email)
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)
      {:ok, request, :created} = join(user, code)
      {:ok, _} = Gyms.approve_join_request(ctx.owner, ctx.gym.id, request.gym_member_id)

      assert {:error, {:conflict, %{gym_member: "already_active"}}} =
               accept(user, {:id, invitation.invitation_id})

      assert %MemberInvitation{status: :pending} =
               Repo.get!(MemberInvitation, invitation.invitation_id)
    end

    test "acceptance needs a completed account", ctx do
      email = address("unregistered")
      {:ok, user} = SimpleFit.Accounts.register_user(:email, email)
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)

      assert {:error, %Ecto.Changeset{}} = accept(user, {:id, invitation.invitation_id})

      assert %MemberInvitation{status: :pending} =
               Repo.get!(MemberInvitation, invitation.invitation_id)
    end
  end

  describe "declining, resending, cancelling" do
    test "decline creates nothing and is final", ctx do
      email = address("decline")
      user = email_user!(email)
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)

      assert {:ok, %{status: :declined}} =
               Gyms.decline_member_invitation(user, {:id, invitation.invitation_id}, client_ip())

      assert {:ok, %{status: :declined}} =
               Gyms.decline_member_invitation(user, {:id, invitation.invitation_id}, client_ip())

      assert {:error, :invitation_unavailable} = accept(user, {:id, invitation.invitation_id})
      assert member_rows(ctx.gym.id, user) == []
      assert [_] = events(ctx.gym.id, :member_invitation_declined)
    end

    test "resend rotates the token after the cooldown; cancel is final and idempotent", ctx do
      email = address("resend")
      user = email_user!(email)
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)
      old = member_token_for(email)

      assert {:error, {:rate_limited, _}} =
               Gyms.resend_member_invitation(ctx.owner, ctx.gym.id, invitation.invitation_id)

      Repo.update_all(from(i in MemberInvitation, where: i.id == ^invitation.invitation_id),
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -120)]
      )

      assert {:ok, %{resends_remaining: 2}} =
               Gyms.resend_member_invitation(ctx.owner, ctx.gym.id, invitation.invitation_id)

      new = member_token_for(email)
      refute new == old
      assert {:error, :invitation_unavailable} = Gyms.preview_member_invitation(old, client_ip())

      assert {:ok, %{status: :cancelled}} =
               Gyms.cancel_member_invitation(ctx.owner, ctx.gym.id, invitation.invitation_id)

      assert {:ok, %{status: :cancelled}} =
               Gyms.cancel_member_invitation(ctx.owner, ctx.gym.id, invitation.invitation_id)

      assert {:error, :invitation_unavailable} = accept(user, {:token, new})
      assert [_] = events(ctx.gym.id, :member_invitation_cancelled)

      other = invite_member!(ctx.owner, ctx.gym.id, address("x"))

      assert {:error, :not_found} =
               Gyms.cancel_member_invitation(registered!("z"), ctx.gym.id, other.invitation_id)
    end

    test "staff and member invitations to one address are independent", ctx do
      email = address("both")
      user = email_user!(email)
      staff = invite!(ctx.owner, ctx.gym.id, email, :coach)
      member = invite_member!(ctx.owner, ctx.gym.id, email)

      assert {:error, :not_found} =
               Gyms.accept_member_invitation(
                 user,
                 live_session!(user),
                 {:id, staff.invitation_id},
                 client_ip()
               )

      assert {:ok, _} = accept(user, {:id, member.invitation_id})
      assert {:ok, %{entries: [%{status: :pending}]}} = Gyms.list_my_staff_invitations(user, %{})
    end
  end

  test "the gym's list shows effective statuses and filters", ctx do
    a = invite_member!(ctx.owner, ctx.gym.id, address("a"))
    _b = invite_member!(ctx.owner, ctx.gym.id, address("b"))

    Repo.update_all(from(i in MemberInvitation, where: i.id == ^a.invitation_id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:ok, %{entries: all}} = Gyms.list_member_invitations(ctx.owner, ctx.gym.id, %{})
    assert length(all) == 2

    assert {:ok, %{entries: [expired]}} =
             Gyms.list_member_invitations(ctx.owner, ctx.gym.id, %{"status" => "expired"})

    assert expired.invitation_id == a.invitation_id

    assert {:ok, %{entries: [_]}} =
             Gyms.list_member_invitations(ctx.owner, ctx.gym.id, %{"status" => "pending"})
  end
end
