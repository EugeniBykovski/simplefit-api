defmodule SimpleFit.Gyms.Policy do
  @moduledoc """
  The fixed gym permission matrix (ADR 0026, D-G03; SF-82 package,
  `02-identity-roles-permissions.md` §4). Permissions derive only from the
  role of an **active** staff membership at one gym; nothing else grants
  them (not an account, a Coach or Fighter profile, a gym participant
  membership, or anything a client sends).

  A grant is `:all` or a named scope that the operation enforces itself
  (for example `:coach_and_front_desk` for a manager removing staff). A role
  without an entry has no grant.

  There is deliberately **no** permission that reads members' private
  training data, messages, RPE, weight, videos or coach notes, for any role
  (D-G06, "never, for any role"): that data is reachable only through a
  Coach–Fighter relationship (ADR 0021).

  The matrix is code, not data: it is not editable by users and custom roles
  are future (D-G03).
  """

  alias SimpleFit.Gyms.StaffMembership

  @type permission ::
          :view_workspace
          | :view_staff
          | :edit_gym
          | :manage_locations
          | :complete_setup
          | :invite_manager
          | :invite_staff
          | :change_staff_role
          | :remove_staff
          | :leave_gym
          | :transfer_ownership
          | :close_gym
          | :manage_member_enrollment
          | :view_members
          | :view_member_contact
          | :change_member_status
          | :manage_timetable
          | :cancel_occurrence
          | :view_rosters
          | :book_for_member
          | :record_check_in
          | :view_attendance
          | :manage_billing

  @type scope ::
          :all
          | :coach_and_front_desk
          | :own_classes
          | :own_occurrences
          | :at_check_in
          | :today

  @staff %{owner: :all, manager: :all, coach: :all, front_desk: :all}
  @admins %{owner: :all, manager: :all}
  @owner %{owner: :all}

  @matrix %{
    view_workspace: @staff,
    view_staff: @staff,
    edit_gym: @admins,
    manage_locations: @admins,
    complete_setup: @owner,
    invite_manager: @owner,
    invite_staff: @admins,
    change_staff_role: %{owner: :all, manager: :coach_and_front_desk},
    remove_staff: %{owner: :all, manager: :coach_and_front_desk},
    # The owner leaves only by transferring ownership (D-G04).
    leave_gym: %{manager: :all, coach: :all, front_desk: :all},
    transfer_ownership: @owner,
    close_gym: @owner,
    manage_member_enrollment: %{owner: :all, manager: :all, front_desk: :all},
    view_members: %{owner: :all, manager: :all, coach: :own_classes, front_desk: :all},
    view_member_contact: %{owner: :all, manager: :all, front_desk: :at_check_in},
    change_member_status: @admins,
    manage_timetable: @admins,
    cancel_occurrence: %{owner: :all, manager: :all, coach: :own_occurrences},
    view_rosters: %{owner: :all, manager: :all, coach: :own_occurrences, front_desk: :all},
    book_for_member: %{owner: :all, manager: :all, front_desk: :all},
    record_check_in: @staff,
    view_attendance: %{owner: :all, manager: :all, coach: :own_occurrences, front_desk: :today},
    # Billing itself is a deferred product decision (D-G09/D-G10); only the
    # owner will ever hold it.
    manage_billing: @owner
  }

  @permissions @matrix |> Map.keys() |> Enum.sort()

  @doc "Every permission, sorted."
  @spec permissions() :: [permission()]
  def permissions, do: @permissions

  @doc "The grant of `role` for `permission`: `:all`, a scope, or `nil` (none)."
  @spec grant(StaffMembership.role(), permission()) :: scope() | nil
  def grant(role, permission) when is_map_key(@matrix, permission),
    do: Map.get(@matrix[permission], role)

  @doc """
  Whether an active staff membership may perform `permission`:
  `{:ok, scope}` or `{:error, :forbidden}`. An ended membership has no grant
  (callers treat it as no membership at all).
  """
  @spec check(StaffMembership.t(), permission()) :: {:ok, scope()} | {:error, :forbidden}
  def check(%StaffMembership{status: :active, role: role}, permission) do
    case grant(role, permission) do
      nil -> {:error, :forbidden}
      scope -> {:ok, scope}
    end
  end

  def check(%StaffMembership{}, permission) when is_map_key(@matrix, permission),
    do: {:error, :forbidden}

  @doc "The permissions `role` holds (any scope), sorted: a read-only projection for clients."
  @spec permissions_of(StaffMembership.role()) :: [permission()]
  def permissions_of(role), do: Enum.filter(@permissions, &grant(role, &1))
end
