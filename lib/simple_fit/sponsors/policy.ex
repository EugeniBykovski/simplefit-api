defmodule SimpleFit.Sponsors.Policy do
  @moduledoc """
  What each sponsor role may do in its own organization (SF-112, ADR 0030; the
  SF-107 matrix, proposed). A fixed matrix in code, as `SimpleFit.Gyms.Policy`,
  applied only to an **active** membership of an organization that isn't closed.
  Nothing else grants any of it: not an account, an intent, an application, a
  contact entry, a gym role or operator authority.

  SF-112 implements the read permissions only. The writes in the SF-107 matrix
  (brand edits, member removal, role changes, invitations, ownership transfer,
  leaving) wait for their decisions (D-SA07, D-SA08, D-SA12) and tasks.

  SF-130 adds partnerships (D-SA38, approved): every role sees the organization's
  partnership preferences and proposals (`view_partnerships`); the owner and
  managers edit preferences and create, edit, submit and withdraw proposals
  (`manage_partnerships`), and only while the organization is active.
  """

  @type role :: :owner | :manager | :member
  @type permission ::
          :view_organization
          | :view_members
          | :view_contacts
          | :view_partnerships
          | :manage_partnerships

  @matrix %{
    view_organization: [:owner, :manager, :member],
    view_members: [:owner, :manager, :member],
    view_contacts: [:owner, :manager],
    view_partnerships: [:owner, :manager, :member],
    manage_partnerships: [:owner, :manager]
  }

  @doc "Every permission, in a stable order."
  @spec permissions() :: [permission()]
  def permissions,
    do: [
      :view_organization,
      :view_members,
      :view_contacts,
      :view_partnerships,
      :manage_partnerships
    ]

  @doc "Whether `role` holds `permission`."
  @spec allowed?(role(), permission()) :: boolean()
  def allowed?(role, permission), do: role in Map.fetch!(@matrix, permission)

  @doc "The permissions `role` holds, for display only (every call checks again)."
  @spec for_role(role()) :: [permission()]
  def for_role(role), do: Enum.filter(permissions(), &allowed?(role, &1))
end
