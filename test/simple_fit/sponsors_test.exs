defmodule SimpleFit.SponsorsTest do
  @moduledoc """
  SF-112: sponsor organizations, memberships, contacts and the internal provisioning
  boundary, in the SQL sandbox. Real-commit races are in `SimpleFit.SponsorsRaceTest`.
  """

  use SimpleFit.DataCase, async: true

  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, completed_gym!: 1]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Sponsors
  alias SimpleFit.Sponsors.{Contact, Membership, Organization, OrganizationEvent, Provisioning}

  defp events(org_id),
    do:
      Repo.all(
        from(e in OrganizationEvent,
          where: e.organization_id == ^org_id,
          order_by: [e.occurred_at, e.id]
        )
      )

  # Deferred constraint triggers run at commit, which the sandbox never reaches.
  defp check_deferred!, do: Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

  describe "the one global user" do
    test "users gain no role, type or sponsor column" do
      assert User.__schema__(:fields) == [:id, :inserted_at, :updated_at]
    end
  end

  describe "provisioning boundary" do
    test "only the fixture authority exists in a test build; approval isn't wired yet" do
      assert {:ok, %Provisioning.Authority{source: :local_fixture}} =
               Provisioning.local_fixture_authority()

      assert {:error, :unavailable} = Provisioning.application_authority(Ecto.UUID.generate())
    end

    test "creates an active organization, its single owner, contacts and history, atomically" do
      owner = registered!("owner")
      %{organization: org, owner: m} = provision!(owner)

      assert %Organization{status: :active, provisioning_source: :local_fixture, revision: 1} =
               org

      assert is_nil(org.source_application_id)
      assert %Membership{role: :owner, status: :active} = m
      assert m.user_id == owner.id

      assert [%Contact{kind: :primary}] =
               Repo.all(from(c in Contact, where: c.organization_id == ^org.id))

      assert Enum.map(events(org.id), &{&1.event, &1.authority}) == [
               {"organization.provisioned", :local_fixture},
               {"membership.added", :local_fixture}
             ]

      check_deferred!()
    end

    test "the same provisioning key: same request, same organization; other request, conflict" do
      owner = registered!("owner")
      attrs = org_attrs(owner)
      a = fixture_authority()

      assert {:ok, %{organization: first}} = Provisioning.provision_organization(a, attrs)
      assert {:ok, %{organization: again}} = Provisioning.provision_organization(a, attrs)
      assert again.id == first.id
      assert Repo.aggregate(Organization, :count) == 1

      assert {:error, {:conflict, %{provisioning_key: "reused"}}} =
               Provisioning.provision_organization(a, %{attrs | display_name: "Other"})
    end

    test "an owner needs completed account registration; input is validated" do
      {:ok, fresh} = Accounts.register_user(:google, "sp-#{System.unique_integer([:positive])}")
      a = fixture_authority()
      owner = registered!("owner")

      assert {:error, {:conflict, %{user: "not_eligible"}}} =
               Provisioning.provision_organization(a, org_attrs(fresh))

      for bad <- [
            %{country_code: "Poland"},
            %{website: "http://insecure.example"},
            %{legal_name: ""},
            %{contacts: []},
            %{contacts: [%{kind: "primary", full_name: "A", email: "not-an-email"}]},
            %{contacts: [%{kind: "additional", full_name: "A", email: "a@b.example"}]}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Provisioning.provision_organization(a, org_attrs(owner, bad)),
               inspect(bad)
      end

      assert Repo.aggregate(Organization, :count) == 0
    end
  end

  describe "database invariants" do
    setup do
      owner = registered!("owner")
      %{organization: org, owner: m} = provision!(owner)
      %{owner: owner, org: org, owner_membership: m}
    end

    test "one owner, one non-revoked membership per user, immutable roles, no deletes", c do
      other = registered!("other")

      assert_raise Ecto.ConstraintError, ~r/one_owner/, fn ->
        Repo.insert!(%Membership{
          organization_id: c.org.id,
          user_id: other.id,
          role: :owner,
          status: :active
        })
      end

      assert_raise Ecto.ConstraintError, ~r/one_per_user/, fn ->
        Repo.insert!(%Membership{
          organization_id: c.org.id,
          user_id: c.owner.id,
          role: :member,
          status: :active
        })
      end

      m = member!(c.org, other)

      assert_raise Postgrex.Error, ~r/immutable/, fn ->
        Repo.update_all(from(x in Membership, where: x.id == ^m.id), set: [role: :owner])
      end

      assert_raise Postgrex.Error, ~r/never deleted/, fn ->
        Repo.delete_all(from(x in Membership, where: x.id == ^m.id))
      end

      assert_raise Postgrex.Error, ~r/never deleted/, fn ->
        Repo.delete_all(from(o in Organization, where: o.id == ^c.org.id))
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from(e in OrganizationEvent, where: e.organization_id == ^c.org.id))
      end
    end

    test "an organization that isn't closed has exactly one active owner, at commit", c do
      Repo.update_all(from(m in Membership, where: m.id == ^c.owner_membership.id),
        set: [status: :suspended, suspended_at: DateTime.utc_now()]
      )

      assert_raise Postgrex.Error, ~r/exactly one active owner/, fn -> check_deferred!() end
    end

    test "no organization without its owner", c do
      assert_raise Postgrex.Error, ~r/exactly one active owner/, fn ->
        Repo.insert!(%Organization{
          legal_name: "Orphan",
          display_name: "Orphan",
          country_code: "PL",
          status: :active,
          provisioning_source: :local_fixture,
          provisioning_key: Ecto.UUID.generate()
        })

        check_deferred!()
      end

      _ = c
    end

    test "provisioning is immutable and a sponsor_application source needs its application", c do
      assert_raise Postgrex.Error, ~r/immutable_provisioning/, fn ->
        Repo.update_all(from(o in Organization, where: o.id == ^c.org.id),
          set: [provisioning_key: Ecto.UUID.generate()]
        )
      end

      assert_raise Ecto.ConstraintError, ~r/provisioning/, fn ->
        Repo.insert!(%Organization{
          legal_name: "X",
          display_name: "X",
          country_code: "PL",
          status: :active,
          provisioning_source: :sponsor_application,
          provisioning_key: Ecto.UUID.generate()
        })
      end
    end
  end

  describe "membership and organization lifecycle" do
    setup do
      owner = registered!("owner")
      %{organization: org, owner: om} = provision!(owner)
      user = registered!("member")
      %{owner: owner, org: org, owner_membership: om, user: user, m: member!(org, user)}
    end

    test "suspend, reinstate, revoke; revoked is final; the owner is protected", c do
      a = fixture_authority()

      assert {:ok, %{status: :suspended}} =
               Provisioning.suspend_membership(a, c.m.id, "security_review")

      assert {:error, :not_found} = Sponsors.get_organization(c.user, c.org.id)

      assert {:ok, %{status: :active}} =
               Provisioning.reinstate_membership(a, c.m.id, "review_cleared")

      assert {:ok, _} = Sponsors.get_organization(c.user, c.org.id)

      assert {:ok, %{status: :revoked}} =
               Provisioning.revoke_membership(a, c.m.id, "left_company")

      assert {:error, :not_found} = Sponsors.get_organization(c.user, c.org.id)

      assert {:error, {:conflict, %{membership: "revoked"}}} =
               Provisioning.reinstate_membership(a, c.m.id, "undo")

      assert_raise Postgrex.Error, ~r/cannot become/, fn ->
        Repo.update_all(from(x in Membership, where: x.id == ^c.m.id),
          set: [status: :active, revoked_at: nil, revoked_reason: nil]
        )
      end

      for op <- [&Provisioning.suspend_membership/3, &Provisioning.revoke_membership/3] do
        assert {:error, {:conflict, %{membership: "owner"}}} =
                 op.(a, c.owner_membership.id, "x_x")
      end

      # A revoked member can be added again: a new membership, history kept.
      assert %Membership{status: :active} = member!(c.org, c.user)
      assert Repo.aggregate(from(x in Membership, where: x.user_id == ^c.user.id), :count) == 2
      check_deferred!()
    end

    test "never a duplicate; never into a suspended organization (owners only come from provisioning)",
         c do
      a = fixture_authority()

      assert {:error, {:conflict, %{membership: "exists"}}} =
               Provisioning.add_member(a, c.org.id, c.user.id, :manager)

      {:ok, _} = Provisioning.suspend_organization(a, c.org.id, "policy_review")

      assert {:error, {:conflict, %{status: "suspended"}}} =
               Provisioning.add_member(a, c.org.id, registered!("y").id, :member)
    end

    test "a suspended organization is read-only; a closed one is gone and revokes everyone", c do
      a = fixture_authority()

      {:ok, %{status: :suspended}} =
        Provisioning.suspend_organization(a, c.org.id, "policy_review")

      assert {:ok, %{organization: %{status: :suspended}}} =
               Sponsors.get_organization(c.user, c.org.id)

      assert Sponsors.workspace_overview(c.user, 25).total == 0

      {:ok, %{status: :closed}} = Provisioning.close_organization(a, c.org.id, "business_closed")
      assert {:error, :not_found} = Sponsors.get_organization(c.owner, c.org.id)
      assert Sponsors.list_my_organizations(c.owner) == []

      assert Repo.all(
               from(m in Membership,
                 where: m.organization_id == ^c.org.id,
                 select: {m.status, m.revoked_reason}
               )
             ) ==
               [{:revoked, "organization_closed"}, {:revoked, "organization_closed"}]

      assert {:error, {:conflict, %{status: "closed"}}} =
               Provisioning.reinstate_organization(a, c.org.id, "undo")

      check_deferred!()
    end

    test "internal reason codes are codes, never free text", c do
      assert {:error, %Ecto.Changeset{}} =
               Provisioning.suspend_membership(fixture_authority(), c.m.id, "Because I said so")
    end
  end

  describe "authorization and tenant isolation" do
    setup do
      a_owner = registered!("a-owner")
      b_owner = registered!("b-owner")
      %{organization: a} = provision!(a_owner)
      %{organization: b} = provision!(b_owner)
      member = registered!("member")
      member!(a, member, :member)
      %{a: a, b: b, a_owner: a_owner, b_owner: b_owner, member: member}
    end

    test "a member reads its organization and members, not contacts", c do
      assert {:ok, %{membership: %{role: :member}, permissions: perms}} =
               Sponsors.get_organization(c.member, c.a.id)

      assert perms == [:view_organization, :view_members]
      assert {:ok, %{entries: members}} = Sponsors.list_members(c.member, c.a.id)
      assert Enum.map(members, & &1.role) == [:owner, :member]
      refute inspect(members) =~ "@"
      assert {:error, :forbidden} = Sponsors.list_contacts(c.member, c.a.id)
      assert {:ok, [_]} = Sponsors.list_contacts(c.a_owner, c.a.id)
    end

    test "organization A's people can't see organization B, and nobody else can see either", c do
      outsider = registered!("outsider")
      gym_owner = registered!("gym-owner")
      _gym = completed_gym!(gym_owner)

      for user <- [c.member, c.a_owner, outsider, gym_owner],
          fun <- [
            &Sponsors.get_organization/2,
            &Sponsors.list_contacts/2,
            fn u, id -> Sponsors.list_members(u, id) end
          ] do
        assert {:error, :not_found} = fun.(user, c.b.id)
      end

      for id <- [Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert {:error, :not_found} = Sponsors.get_organization(c.a_owner, id)
      end
    end

    test "one user, several independent organizations", c do
      member!(c.b, c.member, :manager)

      assert Enum.map(Sponsors.list_my_organizations(c.member), & &1.organization.id) == [
               c.a.id,
               c.b.id
             ]

      [m_a] =
        Repo.all(
          from(m in Membership, where: m.organization_id == ^c.a.id and m.user_id == ^c.member.id)
        )

      {:ok, _} = Provisioning.revoke_membership(fixture_authority(), m_a.id, "left_company")

      assert {:error, :not_found} = Sponsors.get_organization(c.member, c.a.id)
      assert {:ok, %{membership: %{role: :manager}}} = Sponsors.get_organization(c.member, c.b.id)
    end

    test "a contact whose email matches an account grants that account nothing", c do
      victim = registered!("victim")
      email = "victim-#{System.unique_integer([:positive])}@sponsor.example"

      %{organization: org} =
        provision!(c.a_owner, %{contacts: [%{kind: "primary", full_name: "Victim", email: email}]})

      assert Sponsors.list_my_organizations(victim) == []
      assert {:error, :not_found} = Sponsors.get_organization(victim, org.id)
    end

    test "members are paged with a stable cursor", c do
      for i <- 1..3, do: member!(c.a, registered!("m#{i}"))
      {:ok, p1} = Sponsors.list_members(c.a_owner, c.a.id, %{"limit" => "2"})

      {:ok, p2} =
        Sponsors.list_members(c.a_owner, c.a.id, %{"limit" => "2", "cursor" => p1.next_cursor})

      {:ok, p3} =
        Sponsors.list_members(c.a_owner, c.a.id, %{"limit" => "2", "cursor" => p2.next_cursor})

      ids = Enum.map(p1.entries ++ p2.entries ++ p3.entries, & &1.membership_id)
      assert length(ids) == 5 and Enum.uniq(ids) == ids
      assert is_nil(p3.next_cursor)

      assert {:error, %Ecto.Changeset{}} =
               Sponsors.list_members(c.a_owner, c.a.id, %{"cursor" => "garbage"})

      assert {:error, %Ecto.Changeset{}} =
               Sponsors.list_members(c.a_owner, c.a.id, %{"limit" => "500"})
    end

    test "refusals are counted without ids", c do
      ref = make_ref()
      parent = self()
      id = "sf112-#{inspect(ref)}"

      :telemetry.attach(
        id,
        [:simple_fit, :sponsors, :access_denied],
        fn _e, m, meta, _ ->
          send(parent, {:denied, m, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      {:error, :not_found} = Sponsors.get_organization(c.member, c.b.id)
      {:error, :forbidden} = Sponsors.list_contacts(c.member, c.a.id)
      assert_received {:denied, %{count: 1}, %{reason: :not_found} = m1}
      assert_received {:denied, %{count: 1}, %{reason: :forbidden}}
      assert Map.keys(m1) == [:reason]
    end
  end
end
