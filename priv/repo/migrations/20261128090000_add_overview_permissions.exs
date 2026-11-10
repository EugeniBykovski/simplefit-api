defmodule SimpleFit.Repo.Migrations.AddOverviewPermissions do
  @moduledoc """
  SF-121: the operator permissions of the Control Plane overview (AD1), as SF-107
  proposed them (D-SA16, proposed naming):

  * `platform.dashboard.read` - platform counts only, no names.
  * `system.health.read` - health check results and job counts, no payloads.

  Only the catalog check changes; nothing is granted. Rolling back refuses once
  either permission has ever been granted.
  """

  use Ecto.Migration

  @sf116_permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                        sponsors.applications.claim sponsors.applications.request_changes
                        sponsors.applications.approve sponsors.applications.reject
                        sponsors.applications.read_files sponsors.restrict)
  @permissions @sf116_permissions ++ ~w(platform.dashboard.read system.health.read)

  def up do
    permissions(@permissions)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM operator_permission_grants
                 WHERE permission IN ('platform.dashboard.read', 'system.health.read')) THEN
        RAISE EXCEPTION 'SF-121 rollback refused: overview permissions were granted';
      END IF;
    END
    $$;
    """)

    permissions(@sf116_permissions)
  end

  defp permissions(list) do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{Enum.map_join(list, ", ", &"'#{&1}'")})"
           )
  end
end
