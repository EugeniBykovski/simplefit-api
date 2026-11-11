defmodule SimpleFit.Repo.Migrations.AddOversightPermissions do
  @moduledoc """
  SF-123: operator oversight of gyms, coaches and fighters, read-only.

  * Operator permissions `gyms.read` (SF-107), `coaches.read` and `fighters.read`
    (SF-123, separate so a gym reviewer sees no people). Nothing is granted.
  * Two indexes for the operator gym list: a case-insensitive name prefix
    (`lower(name) text_pattern_ops`) and its newest-first order `(inserted_at, id)`.

  Rolling back refuses while any of the permissions is granted (the catalog check
  can't be recreated over such rows).
  """

  use Ecto.Migration

  @sf122_permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                        sponsors.applications.claim sponsors.applications.request_changes
                        sponsors.applications.approve sponsors.applications.reject
                        sponsors.applications.read_files sponsors.restrict
                        platform.dashboard.read system.health.read
                        users.read users.reveal_email users.restrict users.sessions.revoke)
  @permissions @sf122_permissions ++ ~w(gyms.read coaches.read fighters.read)

  def up do
    permissions(@permissions)

    execute("""
    CREATE INDEX gyms_name_prefix_index ON gyms (lower(name) text_pattern_ops)
    """)

    create index(:gyms, [:inserted_at, :id], name: :gyms_created_index)
  end

  def down do
    drop index(:gyms, [:inserted_at, :id], name: :gyms_created_index)
    execute("DROP INDEX gyms_name_prefix_index")
    permissions(@sf122_permissions)
  end

  defp permissions(list) do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{Enum.map_join(list, ", ", &"'#{&1}'")})"
           )
  end
end
