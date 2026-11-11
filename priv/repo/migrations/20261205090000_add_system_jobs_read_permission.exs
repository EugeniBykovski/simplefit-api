defmodule SimpleFit.Repo.Migrations.AddSystemJobsReadPermission do
  @moduledoc """
  SF-126: operator permission `system.jobs.read`, the background job list and one
  job's metadata (never arguments, `meta` or error messages), separate from the
  health page's `system.health.read`. Nothing is granted. No job action exists: retry
  stays blocked until a per-worker policy is approved (D-SA33).

  Rolling back refuses while the permission is granted.
  """

  use Ecto.Migration

  @sf123_permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                        sponsors.applications.claim sponsors.applications.request_changes
                        sponsors.applications.approve sponsors.applications.reject
                        sponsors.applications.read_files sponsors.restrict
                        platform.dashboard.read system.health.read
                        users.read users.reveal_email users.restrict users.sessions.revoke
                        gyms.read coaches.read fighters.read)

  def up, do: permissions(@sf123_permissions ++ ["system.jobs.read"])
  def down, do: permissions(@sf123_permissions)

  defp permissions(list) do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{Enum.map_join(list, ", ", &"'#{&1}'")})"
           )
  end
end
