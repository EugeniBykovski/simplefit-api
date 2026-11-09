defmodule SimpleFit.EntrySponsorTest do
  @moduledoc """
  SF-112: sponsor workspaces in entry resolution (ADR 0017 rules 3-5, ADR 0030).
  Intent `sponsor` is navigation: it creates nothing and grants nothing.
  """

  use SimpleFit.DataCase, async: true

  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, completed_gym!: 1]
  import SimpleFit.FighterOnboardingHelpers, only: [complete_fighter_onboarding!: 1]

  alias SimpleFit.Accounts
  alias SimpleFit.Entry
  alias SimpleFit.Entry.ContextChoice
  alias SimpleFit.Sponsors.{Membership, Organization, Provisioning}

  defp resolve!(user, params \\ %{}) do
    {:ok, entry} = Entry.resolve(user, params)
    entry
  end

  defp revoke!(org, user) do
    m =
      Repo.one!(
        from(m in Membership,
          where: m.organization_id == ^org.id and m.user_id == ^user.id and m.status != :revoked
        )
      )

    {:ok, _} = Provisioning.revoke_membership(fixture_authority(), m.id, "left_company")
  end

  test "an incomplete account goes to registration first, whatever the intent" do
    {:ok, user} =
      Accounts.register_user(:google, "sp-entry-#{System.unique_integer([:positive])}")

    assert %{destination: :account_registration, mandatory: true, sponsor_id: nil} =
             resolve!(user, %{"intent" => "sponsor"})
  end

  test "sponsor intent without a workspace begins an application, and creates nothing" do
    user = registered!("applicant")

    assert %{
             destination: :sponsor_application,
             reason: :sponsor_intent,
             mandatory: false,
             sponsor_id: nil,
             capabilities: [],
             sponsor_workspaces: [],
             sponsor_workspace_count: 0
           } = resolve!(user, %{"intent" => "sponsor"})

    assert Repo.aggregate(Organization, :count) == 0
    assert Repo.aggregate(Membership, :count) == 0
    assert Repo.aggregate(ContextChoice, :count) == 0
  end

  test "one active workspace: its home, and SPONSOR_WORKSPACE" do
    user = registered!("owner")
    %{organization: org} = provision!(user)

    assert %{destination: :sponsor_home, reason: :sponsor_workspace_active, gym_id: nil} =
             entry = resolve!(user, %{"intent" => "sponsor"})

    assert entry.sponsor_id == org.id
    assert entry.capabilities == [:sponsor_workspace]
    assert [%{sponsor_id: id, role: :owner, selected: false}] = entry.sponsor_workspaces
    assert id == org.id

    # Without an intent, a sponsor workspace is the user's one completed context.
    assert %{destination: :sponsor_home, sponsor_id: ^id} = resolve!(user)
  end

  test "several workspaces: choose, then the remembered one while it stays valid" do
    user = registered!("agency")
    %{organization: a} = provision!(user)
    %{organization: b} = provision!(registered!("other-owner"))
    member!(b, user)

    assert %{destination: :context_selection, reason: :sponsor_choice_required, sponsor_id: nil} =
             resolve!(user, %{"intent" => "sponsor"})

    assert {:ok, _} =
             Entry.record_context_choice(user, %{"context" => "sponsor", "sponsor_id" => b.id})

    assert %{destination: :sponsor_home, reason: :last_context, sponsor_id: b_id} =
             resolve!(user, %{"intent" => "sponsor"})

    assert b_id == b.id
    assert %{destination: :sponsor_home, sponsor_id: ^b_id} = resolve!(user)

    revoke!(b, user)

    # The revoked choice is ignored; the one remaining workspace is the home.
    a_id = a.id

    assert %{destination: :sponsor_home, sponsor_id: ^a_id} =
             resolve!(user, %{"intent" => "sponsor"})
  end

  test "revoked, suspended and suspended-organization memberships give no workspace" do
    user = registered!("member")
    %{organization: org} = provision!(registered!("owner"))
    m = member!(org, user)

    assert %{destination: :sponsor_home} = resolve!(user, %{"intent" => "sponsor"})

    {:ok, _} = Provisioning.suspend_membership(fixture_authority(), m.id, "security_review")

    assert %{destination: :sponsor_application, capabilities: []} =
             resolve!(user, %{"intent" => "sponsor"})

    {:ok, _} = Provisioning.reinstate_membership(fixture_authority(), m.id, "review_cleared")

    {:ok, _} = Provisioning.suspend_organization(fixture_authority(), org.id, "policy_review")
    assert %{destination: :sponsor_application} = resolve!(user, %{"intent" => "sponsor"})
    {:ok, _} = Provisioning.reinstate_organization(fixture_authority(), org.id, "review_cleared")

    revoke!(org, user)

    assert %{destination: :sponsor_application, sponsor_workspace_count: 0} =
             resolve!(user, %{"intent" => "sponsor"})
  end

  test "context=sponsor opens a workspace the user may use; any other id is ignored" do
    user = registered!("owner")
    %{organization: mine} = provision!(user)
    %{organization: theirs} = provision!(registered!("stranger"))
    complete_fighter_onboarding!(user)

    mine_id = mine.id

    assert %{
             destination: :sponsor_home,
             reason: :requested_context,
             context: :sponsor,
             sponsor_id: ^mine_id
           } =
             resolve!(user, %{"context" => "sponsor", "sponsor_id" => mine.id})

    for id <- [theirs.id, Ecto.UUID.generate()] do
      assert %{destination: :context_selection, sponsor_id: nil, context: nil} =
               resolve!(user, %{"context" => "sponsor", "sponsor_id" => id})
    end

    assert {:error, %Ecto.Changeset{}} = Entry.resolve(user, %{"context" => "sponsor"})
    assert {:error, %Ecto.Changeset{}} = Entry.resolve(user, %{"sponsor_id" => mine.id})
  end

  test "mixed contexts: fighter, gym and sponsor stay independent" do
    user = registered!("everything")
    complete_fighter_onboarding!(user)
    _gym = completed_gym!(user)
    %{organization: org} = provision!(user)

    entry = resolve!(user)
    assert entry.destination == :context_selection
    assert Enum.sort(entry.capabilities) == [:fighter, :gym_workspace, :sponsor_workspace]

    assert %{destination: :fighter_home} = resolve!(user, %{"intent" => "fighter"})
    assert %{destination: :gym_home} = resolve!(user, %{"intent" => "gym"})
    org_id = org.id

    assert %{destination: :sponsor_home, sponsor_id: ^org_id} =
             resolve!(user, %{"intent" => "sponsor"})

    {:ok, _} =
      Entry.record_context_choice(user, %{"context" => "sponsor", "sponsor_id" => org.id})

    assert %{destination: :sponsor_home, reason: :last_context} = resolve!(user)
    {:ok, _} = Entry.record_context_choice(user, %{"context" => "fighter"})
    assert %{destination: :fighter_home} = resolve!(user)
  end

  test "a sponsor choice needs an active membership of an active organization" do
    user = registered!("chooser")
    %{organization: theirs} = provision!(registered!("stranger"))

    for id <- [theirs.id, Ecto.UUID.generate()] do
      assert {:error, :not_found} =
               Entry.record_context_choice(user, %{"context" => "sponsor", "sponsor_id" => id})
    end

    assert {:error, %Ecto.Changeset{}} =
             Entry.record_context_choice(user, %{"context" => "sponsor"})

    assert Repo.aggregate(ContextChoice, :count) == 0
  end

  test "being an operator or a gym owner never projects a sponsor workspace" do
    user = registered!("gym-owner")
    _gym = completed_gym!(user)
    entry = resolve!(user, %{"intent" => "sponsor"})
    assert entry.destination == :sponsor_application
    refute :sponsor_workspace in entry.capabilities

    refute Enum.any?(
             entry.capabilities,
             &(&1 not in [:fighter, :coach, :gym_workspace, :sponsor_workspace])
           )
  end
end
