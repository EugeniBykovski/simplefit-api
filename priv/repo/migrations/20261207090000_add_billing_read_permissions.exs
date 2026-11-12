defmodule SimpleFit.Repo.Migrations.AddBillingReadPermissions do
  @moduledoc """
  SF-127: operator permissions `billing.read` (the billing overview, the SaaS plan
  catalog, gym subscriptions and Stripe invoice outcomes) and
  `billing.reconciliation.read` (reconciliation discrepancies and webhook inbox
  metadata). Read only: no refund, cancellation, price or entitlement change exists
  behind either. Nothing is granted.

  Rolling back refuses while either permission is granted.
  """

  use Ecto.Migration

  @sf126_permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                        sponsors.applications.claim sponsors.applications.request_changes
                        sponsors.applications.approve sponsors.applications.reject
                        sponsors.applications.read_files sponsors.restrict
                        platform.dashboard.read system.health.read
                        users.read users.reveal_email users.restrict users.sessions.revoke
                        gyms.read coaches.read fighters.read system.jobs.read)

  def up, do: permissions(@sf126_permissions ++ ["billing.read", "billing.reconciliation.read"])
  def down, do: permissions(@sf126_permissions)

  defp permissions(list) do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{Enum.map_join(list, ", ", &"'#{&1}'")})"
           )
  end
end
