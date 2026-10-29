defmodule SimpleFit.GymStaffInvitationsTest do
  @moduledoc """
  Gym staff invitations (SF-93; ADR 0026 D-G12, D-G16, D-G22): who invites
  whom, duplicates, the 7-day expiry, resend and cancel, recipient binding by
  verified email, explicit acceptance creating exactly one membership,
  decline, audit, email delivery and the checklist.
  """

  use SimpleFit.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import SimpleFit.EmailAuthHelpers, only: [emails_to: 1, queued_emails: 0]
  import SimpleFit.GymHelpers

  alias SimpleFit.{Entry, Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, StaffInvitation, StaffMembership}

  setup do
    owner = registered_as!(registered!("staff-owner"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym}
  end

  defp create(user, gym_id, email, role, extra \\ %{}),
    do:
      Gyms.create_staff_invitation(
        user,
        gym_id,
        Map.merge(%{"email" => email, "role" => to_string(role)}, extra),
        client_ip()
      )

  defp accept(user, locator, session \\ nil),
    do: Gyms.accept_staff_invitation(user, session || live_session!(user), locator, client_ip())

  defp decline(user, locator), do: Gyms.decline_staff_invitation(user, locator, client_ip())

  defp events(gym_id, type),
    do: gym_id |> audit_events() |> Enum.filter(&(&1.event_type == type))

  describe "creating (who invites whom)" do
    test "the owner invites a manager, a coach and front desk; the E06 email carries the link",
         ctx do
      for role <- [:manager, :coach, :front_desk] do
        email = address("invitee")
        assert {:ok, view, :created} = create(ctx.owner, ctx.gym.id, email, role)
        assert view.role == role
        assert view.status == :pending
        assert view.recipient_email =~ ~r/\A.•••@example\.com\z/
        assert view.invited_by.name == "Yauheni B."
        assert view.resends_remaining == 3
        assert DateTime.diff(view.expires_at, view.created_at) == 7 * 24 * 3600

        [message] = emails_to(email)
        assert message.subject == "Yauheni invited you to Simple Boxing Gym"
        assert message.text =~ "https://app.simplefit.example/invite/staff#token=sfs_"
        refute message.text =~ "?token="
        refute message.text =~ "Sell drop-ins"
        assert staff_token_for(email) =~ ~r/\Asfs_[A-Za-z0-9_-]{43}\z/
      end

      assert length(events(ctx.gym.id, :staff_invited)) == 3
    end

    test "a manager invites coaches and front desk, never a manager", ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager)
      assert {:ok, _, :created} = create(manager, ctx.gym.id, address(), :coach)
      assert {:ok, _, :created} = create(manager, ctx.gym.id, address(), :front_desk)
      assert create(manager, ctx.gym.id, address(), :manager) == {:error, :forbidden}
    end

    test "coaches and front desk invite nobody", ctx do
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk)

      for user <- [coach, desk], role <- [:manager, :coach, :front_desk] do
        assert create(user, ctx.gym.id, address(), role) == {:error, :forbidden}
      end
    end

    test "nobody is invited as owner, and no other field is accepted", ctx do
      assert {:error, %Ecto.Changeset{} = cs} = create(ctx.owner, ctx.gym.id, address(), :owner)
      assert {"is invalid", _} = cs.errors[:role]

      for extra <- [
            %{"gym_id" => Ecto.UUID.generate()},
            %{"status" => "accepted"},
            %{"user_id" => ctx.owner.id},
            %{"token" => "sfs_x"}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} =
                 create(ctx.owner, ctx.gym.id, address(), :coach, extra)
      end

      assert {:error, %Ecto.Changeset{} = cs} =
               create(ctx.owner, ctx.gym.id, "not an email", :coach)

      assert {"is invalid", _} = cs.errors[:email]
      assert Repo.aggregate(StaffInvitation, :count) == 0
    end

    test "an outsider, an unknown gym and a malformed id are not_found", ctx do
      outsider = registered!("outsider")
      assert create(outsider, ctx.gym.id, address(), :coach) == {:error, :not_found}
      assert create(ctx.owner, Ecto.UUID.generate(), address(), :coach) == {:error, :not_found}
      assert create(ctx.owner, "nope", address(), :coach) == {:error, :not_found}
    end

    test "a draft invites nobody", ctx do
      other = registered!("draft-owner")
      draft = draft_gym!(other)

      assert create(other, draft.id, address(), :coach) ==
               {:error, {:conflict, %{setup_status: "draft"}}}

      _ = ctx
    end

    test "nobody invites an address of their own", ctx do
      email = address("own")
      link_email!(ctx.owner, email)
      assert {:error, %Ecto.Changeset{} = cs} = create(ctx.owner, ctx.gym.id, email, :manager)
      assert {"is your own address", _} = cs.errors[:email]
    end

    test "addresses are normalized like sign-in addresses", ctx do
      email = address("case")

      assert {:ok, view, :created} =
               create(ctx.owner, ctx.gym.id, "  " <> String.upcase(email), :coach)

      assert {:ok, ^view, :existing} = create(ctx.owner, ctx.gym.id, email, :coach)
      assert [_] = emails_to(email)
    end
  end

  describe "duplicates" do
    test "the same address and role returns the pending invitation: no new token or email", ctx do
      email = address()
      {:ok, first, :created} = create(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)

      assert {:ok, ^first, :existing} = create(ctx.owner, ctx.gym.id, email, :coach)
      assert [_] = emails_to(email)
      assert staff_token_for(email) == token
      assert length(events(ctx.gym.id, :staff_invited)) == 1
    end

    test "another role while one is pending is a conflict", ctx do
      email = address()
      {:ok, _, :created} = create(ctx.owner, ctx.gym.id, email, :coach)

      assert create(ctx.owner, ctx.gym.id, email, :manager) ==
               {:error, {:conflict, %{staff_invitation: "pending_other_role"}}}
    end

    test "after a cancel, or past the expiry, the address can be invited again", ctx do
      email = address()
      {:ok, first, :created} = create(ctx.owner, ctx.gym.id, email, :coach)
      {:ok, _} = Gyms.cancel_staff_invitation(ctx.owner, ctx.gym.id, first.invitation_id)
      assert {:ok, second, :created} = create(ctx.owner, ctx.gym.id, email, :manager)

      expire_invitation!(second.invitation_id)
      assert {:ok, third, :created} = create(ctx.owner, ctx.gym.id, email, :manager)
      assert stored_invitation(second.invitation_id).status == :expired

      assert length(Enum.uniq([first.invitation_id, second.invitation_id, third.invitation_id])) ==
               3
    end

    test "an address of an active member of this gym is a conflict", ctx do
      email = address("member")
      user = email_user!(email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      accept!(user, id)

      assert create(ctx.owner, ctx.gym.id, email, :front_desk) ==
               {:error, {:conflict, %{staff_membership: "already_active"}}}
    end

    test "two gyms invite the same address independently", ctx do
      email = address("two-gyms")
      other_owner = registered!("other-owner")
      other = completed_gym!(other_owner)

      assert {:ok, a, :created} = create(ctx.owner, ctx.gym.id, email, :coach)
      assert {:ok, b, :created} = create(other_owner, other.id, email, :manager)
      assert a.invitation_id != b.invitation_id
    end
  end

  describe "resend and cancel" do
    test "resend rotates the token: the old link stops working, the inbox id does not", ctx do
      email = address()
      user = email_user!(email)
      {:ok, view, :created} = create(ctx.owner, ctx.gym.id, email, :coach)
      old = staff_token_for(email)
      backdate_last_sent(view.invitation_id)

      assert {:ok, resent} =
               Gyms.resend_staff_invitation(ctx.owner, ctx.gym.id, view.invitation_id)

      assert resent.resends_remaining == 2
      new = staff_token_for(email)
      assert new != old

      assert Gyms.preview_staff_invitation(old, client_ip()) == {:error, :invitation_unavailable}
      assert {:ok, _} = Gyms.preview_staff_invitation(new, client_ip())
      assert {:ok, %{outcome: :accepted}} = accept(user, {:id, view.invitation_id})
    end

    test "resend: 60 seconds apart, at most 3, only while pending, the inviting role's permission",
         ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager)
      {:ok, view, :created} = create(ctx.owner, ctx.gym.id, address(), :manager)

      assert {:error, {:rate_limited, wait}} =
               Gyms.resend_staff_invitation(ctx.owner, ctx.gym.id, view.invitation_id)

      assert wait in 1..60

      assert Gyms.resend_staff_invitation(manager, ctx.gym.id, view.invitation_id) ==
               {:error, :forbidden}

      for _ <- 1..3 do
        backdate_last_sent(view.invitation_id)
        assert {:ok, _} = Gyms.resend_staff_invitation(ctx.owner, ctx.gym.id, view.invitation_id)
      end

      backdate_last_sent(view.invitation_id)

      assert Gyms.resend_staff_invitation(ctx.owner, ctx.gym.id, view.invitation_id) ==
               {:error, {:conflict, %{resends: "limit_reached"}}}
    end

    test "cancel: final, idempotent, audited; accepted or declined ones cannot be cancelled",
         ctx do
      email = address()
      user = email_user!(email)
      {:ok, view, :created} = create(ctx.owner, ctx.gym.id, email, :coach)

      assert {:ok, %{status: :cancelled} = cancelled} =
               Gyms.cancel_staff_invitation(ctx.owner, ctx.gym.id, view.invitation_id)

      assert {:ok, ^cancelled} =
               Gyms.cancel_staff_invitation(ctx.owner, ctx.gym.id, view.invitation_id)

      assert [_] = events(ctx.gym.id, :staff_invitation_cancelled)
      assert accept(user, {:id, view.invitation_id}) == {:error, :invitation_unavailable}

      {:ok, accepted, :created} = create(ctx.owner, ctx.gym.id, email, :coach)
      accept!(user, accepted.invitation_id)

      assert Gyms.cancel_staff_invitation(ctx.owner, ctx.gym.id, accepted.invitation_id) ==
               {:error, {:conflict, %{staff_invitation: "accepted"}}}
    end

    test "another gym's invitation id is not_found", ctx do
      other_owner = registered!("other")
      other = completed_gym!(other_owner)
      {:ok, view, :created} = create(other_owner, other.id, address(), :coach)

      assert Gyms.cancel_staff_invitation(ctx.owner, ctx.gym.id, view.invitation_id) ==
               {:error, :not_found}

      assert Gyms.resend_staff_invitation(ctx.owner, ctx.gym.id, view.invitation_id) ==
               {:error, :not_found}

      assert stored_invitation(view.invitation_id).status == :pending
    end
  end

  describe "listing (gym side)" do
    test "owner and managers see the invitations with effective statuses; coaches and front desk do not",
         ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager)
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
      {:ok, pending, :created} = create(ctx.owner, ctx.gym.id, address(), :front_desk)
      {:ok, stale, :created} = create(ctx.owner, ctx.gym.id, address(), :coach)
      expire_invitation!(stale.invitation_id)

      assert {:ok, %{entries: entries, next_cursor: nil}} =
               Gyms.list_staff_invitations(manager, ctx.gym.id, %{})

      statuses = Map.new(entries, &{&1.invitation_id, &1.status})
      assert statuses[pending.invitation_id] == :pending
      assert statuses[stale.invitation_id] == :expired

      assert {:ok, %{entries: [only]}} =
               Gyms.list_staff_invitations(ctx.owner, ctx.gym.id, %{"status" => "expired"})

      assert only.invitation_id == stale.invitation_id
      assert Gyms.list_staff_invitations(coach, ctx.gym.id, %{}) == {:error, :forbidden}

      assert {:ok, %{entries: [_], next_cursor: cursor}} =
               Gyms.list_staff_invitations(ctx.owner, ctx.gym.id, %{"limit" => "1"})

      assert {:ok, %{entries: [_]}} =
               Gyms.list_staff_invitations(ctx.owner, ctx.gym.id, %{
                 "limit" => "1",
                 "cursor" => cursor
               })
    end
  end

  describe "the recipient's inbox (verified email identities)" do
    test "a recipient sees only invitations sent to their verified addresses", ctx do
      email = address("inbox")
      user = email_user!(email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      _other = invite!(ctx.owner, ctx.gym.id, address("someone-else"), :coach)

      assert {:ok, %{entries: [entry], next_cursor: nil}} =
               Gyms.list_my_staff_invitations(user, %{})

      assert entry.invitation_id == id
      assert entry.gym == %{gym_id: ctx.gym.id, name: "Simple Boxing Gym"}
      assert entry.invited_by == %{first_name: "Yauheni", role: :owner}
      assert entry.sent_to == email
      assert {:ok, ^entry} = Gyms.get_my_staff_invitation(user, id)

      # Reading changed nothing.
      assert stored_invitation(id).status == :pending
      assert active_memberships(ctx.gym.id, user) == []
    end

    test "a Google-only user has an empty inbox until they verify the address (SF-77)", ctx do
      email = address("google")
      google = registered!("google-only")
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :front_desk)

      assert {:ok, %{entries: []}} = Gyms.list_my_staff_invitations(google, %{})
      assert Gyms.get_my_staff_invitation(google, id) == {:error, :not_found}
      assert accept(google, {:id, id}) == {:error, :not_found}

      link_email!(google, email)

      assert {:ok, %{entries: [%{invitation_id: ^id}]}} =
               Gyms.list_my_staff_invitations(google, %{})

      assert {:ok, %{outcome: :accepted, role: :front_desk}} = accept(google, {:id, id})
    end

    test "an invitation to an unregistered address creates no account", ctx do
      users_before = Repo.aggregate(SimpleFit.Accounts.User, :count)
      invite!(ctx.owner, ctx.gym.id, address("nobody"), :coach)
      assert Repo.aggregate(SimpleFit.Accounts.User, :count) == users_before
    end
  end

  describe "accepting" do
    test "explicit acceptance creates exactly one membership, consumes the invitation and audits",
         ctx do
      email = address("accept")
      user = email_user!(email, "Natalia Wiśniewska")
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :manager)

      assert {:ok, result} = accept(user, {:id, id})
      assert result.outcome == :accepted
      assert result.gym_id == ctx.gym.id
      assert result.role == :manager
      assert result.invitation.status == :accepted

      assert [%StaffMembership{id: membership_id, role: :manager}] =
               active_memberships(ctx.gym.id, user)

      assert result.staff_membership_id == membership_id
      stored = stored_invitation(id)
      assert {stored.status, stored.staff_membership_id} == {:accepted, membership_id}
      assert %DateTime{} = stored.responded_at

      assert [%AuditEvent{actor_user_id: actor, staff_invitation_id: ^id}] =
               events(ctx.gym.id, :staff_invitation_accepted)

      assert actor == user.id

      assert [_owner_created, %AuditEvent{staff_membership_id: ^membership_id, to_role: :manager}] =
               events(ctx.gym.id, :staff_membership_created)

      # The gym is now one of the user's workspaces (SF-84), with the new role.
      assert {:ok, %{role: :manager}} = Gyms.workspace(user, ctx.gym.id)
      assert {:ok, %{viewer: %{role: :manager}}} = Gyms.get_gym(user, ctx.gym.id)
    end

    test "a repeated acceptance returns the same membership; nothing else changes", ctx do
      email = address()
      user = email_user!(email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)

      {:ok, first} = accept(user, {:id, id})
      assert {:ok, again} = accept(user, {:id, id})
      assert again.outcome == :already_accepted
      assert again.staff_membership_id == first.staff_membership_id
      assert {:ok, %{outcome: :already_accepted}} = accept(user, {:token, token})
      assert [_] = active_memberships(ctx.gym.id, user)
      assert [_] = events(ctx.gym.id, :staff_invitation_accepted)
    end

    test "by token: the web link, bound to the verified address", ctx do
      email = address("token")
      user = email_user!(email)
      intruder = email_user!(address("intruder"))
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)

      assert accept(intruder, {:token, token}) == {:error, :invitation_recipient_mismatch}
      assert decline(intruder, {:token, token}) == {:error, :invitation_recipient_mismatch}
      assert accept(intruder, {:id, id}) == {:error, :not_found}
      assert active_memberships(ctx.gym.id, intruder) == []

      assert {:ok, %{outcome: :accepted}} = accept(user, {:token, token})
      # A used token is unavailable to anyone else; no state oracle.
      assert accept(intruder, {:token, token}) == {:error, :invitation_unavailable}
    end

    test "forged, malformed, cancelled, declined and expired tokens are all unavailable", ctx do
      email = address()
      user = email_user!(email)

      for token <- [nil, "", "sfs_short", "sfi_" <> String.duplicate("a", 43), 123] do
        assert accept(user, {:token, token}) == {:error, :invitation_unavailable}

        assert Gyms.preview_staff_invitation(token, client_ip()) ==
                 {:error, :invitation_unavailable}
      end

      forged = "sfs_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      assert accept(user, {:token, forged}) == {:error, :invitation_unavailable}

      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)
      expire_invitation!(id)
      assert accept(user, {:token, token}) == {:error, :invitation_unavailable}
      assert accept(user, {:id, id}) == {:error, :invitation_unavailable}

      assert Gyms.preview_staff_invitation(token, client_ip()) ==
               {:error, :invitation_unavailable}

      assert active_memberships(ctx.gym.id, user) == []
      assert {:ok, %{status: :expired}} = Gyms.get_my_staff_invitation(user, id)
    end

    test "the wrong account, a foreign id and a malformed id never accept", ctx do
      email = address()
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      other = email_user!(address("other"))

      assert accept(other, {:id, id}) == {:error, :not_found}
      assert accept(other, {:id, Ecto.UUID.generate()}) == {:error, :not_found}
      assert accept(other, {:id, "nope"}) == {:error, :not_found}
      assert stored_invitation(id).status == :pending
    end

    test "acceptance needs completed account registration, nothing more", ctx do
      email = address("unregistered")
      {:ok, user} = SimpleFit.Accounts.register_user(:email, email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)

      assert {:error, %Ecto.Changeset{} = cs} = accept(user, {:id, id})
      assert {"must be completed first", _} = cs.errors[:account_registration]
      assert stored_invitation(id).status == :pending

      registered_as!(user, "Kuba Nowak")
      assert {:ok, %{outcome: :accepted}} = accept(user, {:id, id})
    end

    test "a revoked or foreign session never accepts", ctx do
      email = address()
      user = email_user!(email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      {:ok, credentials} = SimpleFit.Accounts.create_session(user)
      :ok = SimpleFit.Accounts.revoke_session({:access, credentials.access_token})

      assert accept(user, {:id, id}, credentials.session) == {:error, :session_revoked}

      assert accept(user, {:id, id}, live_session!(registered!("someone"))) ==
               {:error, :session_revoked}

      assert stored_invitation(id).status == :pending
    end

    test "an already active member keeps their role; the invitation stays pending", ctx do
      email = address()
      user = email_user!(email)
      second = address("second")
      link_email!(user, second)
      %{invitation_id: first} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      %{invitation_id: other} = invite!(ctx.owner, ctx.gym.id, second, :manager)

      accept!(user, first)

      assert accept(user, {:id, other}) ==
               {:error, {:conflict, %{staff_membership: "already_active"}}}

      assert [%{role: :coach}] = active_memberships(ctx.gym.id, user)
      assert stored_invitation(other).status == :pending
    end

    test "an invitation whose inviter was removed or demoted can no longer be accepted", ctx do
      {manager, %{staff_membership_id: manager_id}} =
        joined_staff!(ctx.owner, ctx.gym.id, :manager)

      email_a = address("a")
      email_b = address("b")
      a = email_user!(email_a)
      b = email_user!(email_b)
      %{invitation_id: ia} = invite!(manager, ctx.gym.id, email_a, :coach)

      {:ok, _} = Gyms.change_staff_role(ctx.owner, ctx.gym.id, manager_id, %{"role" => "coach"})
      assert stored_invitation(ia).status == :cancelled
      assert accept(a, {:id, ia}) == {:error, :invitation_unavailable}

      {:ok, _} = Gyms.change_staff_role(ctx.owner, ctx.gym.id, manager_id, %{"role" => "manager"})
      %{invitation_id: ib} = invite!(manager, ctx.gym.id, email_b, :front_desk)
      {:ok, _} = Gyms.end_staff_membership(ctx.owner, ctx.gym.id, manager_id)
      assert stored_invitation(ib).status == :cancelled
      assert accept(b, {:id, ib}) == {:error, :invitation_unavailable}

      assert length(events(ctx.gym.id, :staff_invitation_cancelled)) == 2
    end
  end

  describe "declining" do
    test "creates nothing, is final, repeats the same answer", ctx do
      email = address()
      user = email_user!(email)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :manager)

      assert {:ok, %{status: :declined} = declined} = decline(user, {:id, id})
      assert {:ok, ^declined} = decline(user, {:id, id})
      assert accept(user, {:id, id}) == {:error, :invitation_unavailable}
      assert active_memberships(ctx.gym.id, user) == []
      assert [_] = events(ctx.gym.id, :staff_invitation_declined)
    end

    test "by token, for the recipient only", ctx do
      email = address()
      user = email_user!(email)
      invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)

      assert {:ok, %{status: :declined}} = decline(user, {:token, token})
      assert decline(user, {:token, token}) == {:ok, elem(decline(user, {:token, token}), 1)}
    end
  end

  describe "preview (the web link before sign-in)" do
    test "only the gym name, role, inviter first name and role, and the expiry", ctx do
      email = address()
      invite!(ctx.owner, ctx.gym.id, email, :front_desk)
      token = staff_token_for(email)

      assert {:ok, preview} = Gyms.preview_staff_invitation(token, client_ip())

      assert Map.keys(preview) |> Enum.sort() == [:expires_at, :gym, :invited_by, :role]
      assert preview.gym == %{name: "Simple Boxing Gym"}
      assert preview.invited_by == %{first_name: "Yauheni", role: :owner}
      refute inspect(preview) =~ email
      refute inspect(preview) =~ ctx.gym.id
    end
  end

  describe "the opening-week checklist (SF-90)" do
    test "invite_staff: available, not completed by sending, completed by an acceptance, kept after removal",
         ctx do
      email = address()
      user = email_user!(email)
      assert item(ctx.owner, ctx.gym.id) == :available

      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      assert item(ctx.owner, ctx.gym.id) == :available

      %{staff_membership_id: membership_id} = accept!(user, id)
      assert item(ctx.owner, ctx.gym.id) == :completed

      {:ok, _} = Gyms.end_staff_membership(ctx.owner, ctx.gym.id, membership_id)
      assert item(ctx.owner, ctx.gym.id) == :completed
    end
  end

  describe "entry (SF-84)" do
    test "accepting adds the gym workspace without switching the current context", ctx do
      email = address()
      user = email_user!(email)
      {:ok, before} = Entry.resolve(user)
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      accept!(user, id)
      {:ok, after_accept} = Entry.resolve(user)

      refute :gym_workspace in before.capabilities
      assert :gym_workspace in after_accept.capabilities
      assert after_accept.gym_workspace_count == 1

      assert Enum.any?(
               after_accept.gym_workspaces,
               &(&1.gym_id == ctx.gym.id and &1.role == :coach)
             )

      # Nothing was chosen for the user: no remembered context.
      assert Repo.aggregate(
               from(c in "entry_context_choices", where: c.user_id == type(^user.id, :binary_id)),
               :count
             ) == 0
    end
  end

  describe "secrets" do
    test "the token, the address and the digest never appear in a view, the audit or the database plainly",
         ctx do
      email = address("secret")
      %{invitation_id: id} = invite!(ctx.owner, ctx.gym.id, email, :coach)
      token = staff_token_for(email)
      stored = stored_invitation(id)

      refute stored.recipient_sealed =~ email
      assert byte_size(stored.token_hash) == 32
      refute inspect(stored) =~ email
      refute inspect(audit_events(ctx.gym.id)) =~ email

      {:ok, %{entries: entries}} = Gyms.list_staff_invitations(ctx.owner, ctx.gym.id, %{})
      refute inspect(entries) =~ email
      refute inspect(entries) =~ token

      # Only the queued, encrypted email job carries the token.
      jobs = Repo.all(from(j in Oban.Job, select: j.args))
      refute inspect(jobs) =~ token
      refute inspect(jobs) =~ email
      assert Enum.any?(queued_emails(), &(&1.text =~ token))
    end
  end

  defp item(owner, gym_id) do
    {:ok, state} = Gyms.get_first_run(owner, gym_id)
    Enum.find(state.checklist, &(&1.key == :invite_staff)).status
  end

  defp backdate_last_sent(id) do
    at = DateTime.add(DateTime.utc_now(), -120)

    {1, _} =
      Repo.update_all(from(i in StaffInvitation, where: i.id == ^id), set: [last_sent_at: at])
  end
end
