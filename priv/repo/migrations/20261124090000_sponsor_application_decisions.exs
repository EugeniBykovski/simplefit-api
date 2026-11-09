defmodule SimpleFit.Repo.Migrations.SponsorApplicationDecisions do
  @moduledoc """
  SF-116 (ADR 0033): operator decisions on sponsor applications.

  * Operator permissions `sponsors.applications.approve`, `.reject`, `.read_files` and
    `sponsors.restrict` (suspend or reinstate an approved application's organization).
  * Sponsor organization history may name `platform_operator` as the authority of a
    suspension or reinstatement.
  * Sponsor application notifications of a decision: `application_approved`,
    `application_rejected`.

  Approval and rejection need no new columns: `status` and `decided_at` exist, and
  the existing trigger already allows `under_review -> approved | rejected`. One
  organization per application is already unique (`source_application_id`).

  Rolling back refuses once any of these new values is in use.
  """

  use Ecto.Migration

  @sf114_permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                        sponsors.applications.claim sponsors.applications.request_changes)
  @permissions @sf114_permissions ++
                 ~w(sponsors.applications.approve sponsors.applications.reject
                    sponsors.applications.read_files sponsors.restrict)

  @sf112_authorities ~w(sponsor_application local_fixture organization_member system)
  @authorities @sf112_authorities ++ ~w(platform_operator)

  @sf114_kinds ~w(application_received application_resubmitted changes_requested
                  contact_verification_code)
  @kinds @sf114_kinds ++ ~w(application_approved application_rejected)

  def up do
    permissions(@permissions)
    authorities(@authorities)
    kinds(@kinds)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM operator_permission_grants
                 WHERE permission IN ('sponsors.applications.approve', 'sponsors.applications.reject',
                                      'sponsors.applications.read_files', 'sponsors.restrict'))
         OR EXISTS (SELECT 1 FROM sponsor_organization_events WHERE authority = 'platform_operator')
         OR EXISTS (SELECT 1 FROM sponsor_application_notifications
                    WHERE kind IN ('application_approved', 'application_rejected'))
         OR EXISTS (SELECT 1 FROM sponsor_applications WHERE status IN ('approved', 'rejected')) THEN
        RAISE EXCEPTION 'SF-116 rollback refused: sponsor application decisions exist';
      END IF;
    END
    $$;
    """)

    kinds(@sf114_kinds)
    authorities(@sf112_authorities)
    permissions(@sf114_permissions)
  end

  defp permissions(list) do
    drop constraint(:operator_permission_grants, :permission_catalog)

    create constraint(:operator_permission_grants, :permission_catalog,
             check: "permission IN (#{quoted(list)})"
           )
  end

  # The SF-112 `codes` check, with the authority list as given.
  defp authorities(list) do
    drop constraint(:sponsor_organization_events, :codes)

    create constraint(:sponsor_organization_events, :codes,
             check:
               "event ~ '^[a-z][a-z0-9_.]{1,79}$' AND " <>
                 "authority IN (#{quoted(list)}) AND " <>
                 "(role IS NULL OR role IN ('owner', 'manager', 'member')) AND " <>
                 "(from_state IS NULL OR from_state ~ '^[a-z][a-z0-9_]{0,39}$') AND " <>
                 "(to_state IS NULL OR to_state ~ '^[a-z][a-z0-9_]{0,39}$') AND " <>
                 "(reason_code IS NULL OR reason_code ~ '^[a-z][a-z0-9_]{1,59}$') AND " <>
                 "(request_id IS NULL OR char_length(request_id) <= 200)"
           )
  end

  # The SF-114 `shape` check, with the kind list as given.
  defp kinds(list) do
    drop constraint(:sponsor_application_notifications, :shape)

    create constraint(:sponsor_application_notifications, :shape,
             check:
               "kind IN (#{quoted(list)}) AND " <>
                 "recipient IN ('applicant', 'contact') AND status IN ('queued', 'suppressed') AND " <>
                 "((status = 'suppressed') = (suppressed_reason IS NOT NULL)) AND " <>
                 "(suppressed_reason IS NULL OR suppressed_reason ~ '^[a-z][a-z0-9_]{1,59}$') AND " <>
                 "char_length(dedupe_key) BETWEEN 1 AND 200"
           )
  end

  defp quoted(list), do: Enum.map_join(list, ", ", &"'#{&1}'")
end
