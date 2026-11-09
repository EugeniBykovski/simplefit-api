defmodule SimpleFit.SponsorHelpers do
  @moduledoc """
  SF-112 test helpers: organizations and memberships through the real internal
  provisioning boundary with the local fixture authority (test builds only).
  """

  alias SimpleFit.Accounts.User
  alias SimpleFit.Sponsors.Provisioning

  @doc "The local fixture authority."
  def fixture_authority do
    {:ok, authority} = Provisioning.local_fixture_authority()
    authority
  end

  @doc "Valid provisioning attributes for `owner`, with `overrides` on top."
  def org_attrs(%User{} = owner, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        provisioning_key: Ecto.UUID.generate(),
        legal_name: "Sponsor #{n} Sp. z o.o.",
        display_name: "Sponsor #{n}",
        country_code: "PL",
        website: "https://sponsor-#{n}.example",
        owner_user_id: owner.id,
        contacts: [
          %{
            kind: "primary",
            full_name: "Ada Nowak",
            job_title: "Partnerships",
            email: "ada.#{n}@sponsor.example",
            phone: "+48123456789"
          }
        ]
      },
      overrides
    )
  end

  @doc "Provisions an organization owned by `owner` (asserting success)."
  def provision!(%User{} = owner, overrides \\ %{}) do
    {:ok, %{organization: org, owner: membership}} =
      Provisioning.provision_organization(fixture_authority(), org_attrs(owner, overrides))

    %{organization: org, owner: membership}
  end

  @doc "Adds `user` to `org` as `role` (asserting success)."
  def member!(org, %User{} = user, role \\ :member) do
    {:ok, membership} = Provisioning.add_member(fixture_authority(), org.id, user.id, role)
    membership
  end
end
