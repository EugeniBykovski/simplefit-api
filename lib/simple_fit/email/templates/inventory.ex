defmodule SimpleFit.Email.Templates.Inventory do
  @moduledoc """
  Every email designed in Claude Design, page Public Website, section
  "14 · Email templates · after registration" (ADR 0011).

  This is the traceability record between production templates and their
  artboards. It records what the design defines and nothing more: a field
  the design does not define is `"NOT_SPECIFIED"`. Subjects of templates not
  implemented are the design's sample subject (with sample data), not a
  production contract.

  Statuses:

    * `"IMPLEMENTED_TEMPLATE / TRIGGER_AVAILABLE"`
    * `"IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED"`
    * `"DESIGN_ONLY / DOMAIN_NOT_AVAILABLE"`
    * `"AMBIGUOUS / NEEDS_PRODUCT_DECISION"`
  """

  @artifact "https://claude.ai/artifact/JEsBg51MjX8KiHWEro8omY"
  @version "1791276973-ad1d"
  @section "Public Website · 14 · Email templates · after registration"
  @delivery "simplefit-api · SimpleFit.Email (Oban mailers queue)"
  @ns "NOT_SPECIFIED"

  @implemented_deferred "IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED"
  @design_only "DESIGN_ONLY / DOMAIN_NOT_AVAILABLE"
  @ambiguous "AMBIGUOUS / NEEDS_PRODUCT_DECISION"

  @statuses [
    "IMPLEMENTED_TEMPLATE / TRIGGER_AVAILABLE",
    @implemented_deferred,
    @design_only,
    @ambiguous
  ]

  @entries [
    %{
      id: "E01",
      name: "Verify your email",
      trigger: "Email sign-up: confirm the address with a code (SF-21)",
      subject: "Your SimpleFit code: {code}",
      preheader: "Enter it in the app to confirm your email.",
      required_variables: ["code", "verify_url", "expires_in_minutes"],
      optional_variables: [],
      primary_cta: "Verify email → verify_url",
      fallback_url:
        "The 6-digit code is the alternative to the link; the plain-text part carries the full URL",
      artboard: "EmailVerify.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :verify_email,
      module: SimpleFit.Email.Templates.VerifyEmail,
      trigger_owner: "SF-21"
    },
    %{
      id: "E02",
      name: "Welcome, fighter",
      trigger: "NOT_SPECIFIED (artboard links F01; after fighter registration)",
      subject: "You’re in, {first_name} — here’s your first week",
      preheader: "Your class, your camp and the round timer are set.",
      required_variables: [
        "first_name",
        "camp_weeks",
        "camp_ends_on",
        "first_class_time",
        "first_class_name",
        "gym_name",
        "first_class_room",
        "first_class_bring",
        "next_class_hint",
        "app_url",
        "preferences_url",
        "unsubscribe_url"
      ],
      optional_variables: [],
      primary_cta: "Open SimpleFit → app_url",
      fallback_url:
        "The plain-text part carries every URL; Email preferences and Unsubscribe URLs are presentation data (no preference system exists)",
      artboard: "EmailWelcomeFighter.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :welcome_fighter,
      module: SimpleFit.Email.Templates.WelcomeFighter,
      trigger_owner:
        "NOT_SPECIFIED (no ticket yet: fighter profile, fight camp, gym and booking domains)"
    },
    %{
      id: "E03",
      name: "Welcome, coach",
      trigger: "NOT_SPECIFIED (artboard links OC5; after coach registration)",
      subject: "Your coaching space is ready",
      preheader: "Invite fighters, finish payouts, get your verified badge.",
      required_variables: ["coaching_name", "invite_url", "payouts_url"],
      optional_variables: [],
      primary_cta: "Finish payouts → payouts_url",
      fallback_url:
        "The plain-text part carries the full URL; the design shows no other fallback",
      artboard: "EmailWelcomeCoach.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :welcome_coach,
      module: SimpleFit.Email.Templates.WelcomeCoach,
      trigger_owner:
        "NOT_SPECIFIED (no ticket yet: coach profile, identity check, licence review and payout domains)"
    },
    %{
      id: "E04",
      name: "Finish gym setup",
      trigger: "NOT_SPECIFIED (artboard links OG1; gym owner registration)",
      subject: "Finish setting up Simple Boxing Gym (sample)",
      preheader: "Your secure setup link — about 20 minutes on a computer.",
      required_variables: @ns,
      optional_variables: @ns,
      primary_cta: "Continue setup",
      fallback_url: @ns,
      artboard: "EmailWelcomeGym.dc.html",
      delivery_owner: @delivery,
      status: @ambiguous,
      note:
        "Not implemented: the approved copy “This link signs you in and is valid for 24 hours” promises sign-in by email link, which the session model (ADR 0010) does not have; “Book a free 15-minute setup call with Gym Success” has no destination. Needs a product/security decision or revised copy."
    },
    %{
      id: "E05",
      name: "Your gym is live",
      trigger: "NOT_SPECIFIED (artboard links WG1; gym published)",
      subject: "{gym_name} is live",
      preheader: "Members can find you, book and pay from today.",
      required_variables: [
        "gym_name",
        "published_on",
        "city",
        "payout_day",
        "public_page_url",
        "locations",
        "member_invites",
        "verification_status",
        "dashboard_url"
      ],
      optional_variables: [],
      primary_cta: "Open dashboard → dashboard_url",
      fallback_url:
        "The plain-text part carries the full URL; the design shows no other fallback",
      artboard: "EmailGymLive.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :gym_live,
      module: SimpleFit.Email.Templates.GymLive,
      trigger_owner:
        "NOT_SPECIFIED (no ticket yet: gym, location, member-import, verification and payout domains)"
    },
    %{
      id: "E06",
      name: "Staff invitation",
      trigger: "NOT_SPECIFIED (artboard links OS1; gym owner invites staff)",
      subject: "{inviter_name} invited you to {gym_name}",
      preheader: "Join the team as {role} · {location}.",
      required_variables: [
        "invitee_name",
        "inviter_name",
        "inviter_display_name",
        "inviter_role",
        "gym_name",
        "role",
        "location",
        "permissions",
        "accept_url",
        "expires_on"
      ],
      optional_variables: [],
      primary_cta: "Accept invitation → accept_url",
      fallback_url:
        "The plain-text part carries the full URL; the design shows no other fallback",
      artboard: "EmailStaffInvite.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :staff_invite,
      module: SimpleFit.Email.Templates.StaffInvite,
      trigger_owner:
        "NOT_SPECIFIED (no ticket yet: gym workspace, staff role and invitation domains)"
    },
    %{
      id: "E07",
      name: "Member invite from gym",
      trigger: "NOT_SPECIFIED (artboard links A03; gym imports members)",
      subject: "{gym_name} is now on SimpleFit",
      preheader: "Claim your {plan} membership — book and check in from your phone.",
      required_variables: [
        "member_name",
        "gym_name",
        "plan",
        "active_until",
        "home_location",
        "claim_url",
        "opt_out_url"
      ],
      optional_variables: [],
      primary_cta: "Claim my membership → claim_url",
      fallback_url:
        "The plain-text part carries both URLs; the opt-out URL is presentation data (no opt-out flow exists)",
      artboard: "EmailMemberInvite.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :member_invite,
      module: SimpleFit.Email.Templates.MemberInvite,
      trigger_owner: "NOT_SPECIFIED (no ticket yet: gym membership and member-import domains)"
    },
    %{
      id: "E08",
      name: "Coach invited you",
      trigger: "NOT_SPECIFIED (artboard links A03; coach invites a fighter)",
      subject: "{coach_name} invited you to train with {coaching_name}",
      preheader: "Join {coach_possessive} team on SimpleFit — your log stays yours.",
      required_variables: [
        "fighter_name",
        "coach_name",
        "coach_initials",
        "coaching_name",
        "coach_tagline",
        "coach_possessive",
        "message",
        "join_url"
      ],
      optional_variables: [],
      primary_cta: "Join {coach_name}’s team → join_url",
      fallback_url:
        "The plain-text part carries the full URL; the design shows no other fallback",
      artboard: "EmailCoachInvite.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :coach_invite,
      module: SimpleFit.Email.Templates.CoachInvite,
      trigger_owner:
        "NOT_SPECIFIED (no ticket yet: coach profile, coach–fighter relationship, invitation and moderation domains)"
    },
    %{
      id: "E09",
      name: "Join request approved",
      trigger: "NOT_SPECIFIED (artboard links F16; gym confirms a membership)",
      subject: "You’re in at {gym_name}",
      preheader: "Your membership is confirmed — check in with your phone.",
      required_variables: [
        "gym_name",
        "staff_name",
        "plan",
        "next_billing",
        "booked",
        "notice_days",
        "checkin_url"
      ],
      optional_variables: [],
      primary_cta: "Show my check-in QR → checkin_url",
      fallback_url:
        "The plain-text part carries the full URL; the design shows no other fallback",
      artboard: "EmailJoinApproved.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :join_approved,
      module: SimpleFit.Email.Templates.JoinApproved,
      trigger_owner: "NOT_SPECIFIED (no ticket yet: gym membership, billing and booking domains)"
    },
    %{
      id: "E10",
      name: "New sign-in alert",
      trigger: "Sign-in from a new device (from artboard copy)",
      subject: "New sign-in from Firefox on Windows (sample)",
      preheader: "If this was you, there’s nothing to do.",
      required_variables: @ns,
      optional_variables: @ns,
      primary_cta: "Secure my account",
      fallback_url: @ns,
      artboard: "EmailNewSignIn.dc.html",
      delivery_owner: @delivery,
      status: @ambiguous,
      note:
        "Not implemented: sessions store no device or location (ADR 0010) and there is no new-device detection; the sample method “Password + authenticator” does not exist (passkeys and identity providers only); the copy promises a 24-hour posting/messaging pause and a secure-account flow that signs out every other device and confirms with a passkey, neither of which exists. Needs revised copy or those features."
    },
    %{
      id: "E11",
      name: "Recover account",
      trigger: "Account recovery: sign in without the passkey (expected SF-28)",
      subject: "Recover your SimpleFit account",
      preheader: "Use this link within {expires_in_minutes} minutes.",
      required_variables: ["recovery_url", "code", "expires_in_minutes"],
      optional_variables: [],
      primary_cta: "Sign in and add a new passkey → recovery_url",
      fallback_url:
        "The recovery code is the alternative to the link; the plain-text part carries the full URL",
      artboard: "EmailRecover.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :recover_account,
      module: SimpleFit.Email.Templates.RecoverAccount,
      trigger_owner: "SF-28 (expected)"
    },
    %{
      id: "E12",
      name: "First week recap",
      trigger: "NOT_SPECIFIED (weekly recap, artboard links B21; product email)",
      subject: "Your first week: {trainings} trainings, {rounds} rounds",
      preheader:
        "Your Board has its first nodes — and {rival_name} is {rival_rounds_ahead} rounds ahead.",
      required_variables: [
        "first_name",
        "trainings",
        "rounds",
        "partners",
        "board_items",
        "challenge_name",
        "challenge_rank",
        "challenge_participants",
        "rival_name",
        "rival_rounds_ahead",
        "board_url",
        "preferences_url",
        "unsubscribe_url"
      ],
      optional_variables: [],
      primary_cta: "See your Board → board_url",
      fallback_url:
        "The plain-text part carries every URL; Email preferences and Unsubscribe URLs are presentation data (no preference system exists)",
      artboard: "EmailWeek1.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :first_week_recap,
      module: SimpleFit.Email.Templates.FirstWeekRecap,
      trigger_owner:
        "NOT_SPECIFIED (no ticket yet: training, Board, challenge and email-preference domains)"
    },
    %{
      id: "E13",
      name: "Account suspended",
      trigger: "NOT_SPECIFIED (moderation suspends an account, artboard links ST15)",
      subject: "Your SimpleFit account is suspended until {suspended_until}",
      preheader: "Why, what still works, and how to appeal.",
      required_variables: [
        "name",
        "case_id",
        "suspended_until",
        "content_kind",
        "posted_on",
        "rule",
        "content_removed",
        "suspension",
        "previous_notices",
        "appeal_url"
      ],
      optional_variables: [],
      primary_cta: "Appeal this decision → appeal_url",
      fallback_url:
        "The plain-text part carries the full URL; the design shows no other fallback",
      artboard: "EmailSuspended.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :account_suspended,
      module: SimpleFit.Email.Templates.AccountSuspended,
      trigger_owner: "NOT_SPECIFIED (no ticket yet: moderation, report and appeal domains)"
    },
    %{
      id: "E14",
      name: "Deletion scheduled",
      trigger: "Account deletion requested (expected SF-28)",
      subject: "Your account will be deleted on {deletion_on}",
      preheader: "Changed your mind? Restore it with one tap before then.",
      required_variables: ["requested_on", "deletion_on", "restore_url", "data_download_url"],
      optional_variables: [],
      primary_cta: "Restore my account → restore_url",
      fallback_url: "The plain-text part carries both URLs; the design shows no other fallback",
      artboard: "EmailDeleteScheduled.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :deletion_scheduled,
      module: SimpleFit.Email.Templates.DeletionScheduled,
      trigger_owner: "SF-28 (expected)"
    },
    %{
      id: "E15",
      name: "Account deleted",
      trigger: "Account permanently deleted (expected SF-28)",
      subject: "Your SimpleFit account has been deleted",
      preheader: "This is the last email we’ll send you.",
      required_variables: ["name", "requested_on", "site_url"],
      optional_variables: [],
      primary_cta: "Visit SimpleFit → site_url",
      fallback_url:
        "The plain-text part carries the full URL; the design shows no other fallback",
      artboard: "EmailDeleted.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :account_deleted,
      module: SimpleFit.Email.Templates.AccountDeleted,
      trigger_owner: "SF-28 (expected)"
    },
    %{
      id: "E16",
      name: "Data export ready",
      trigger: "NOT_SPECIFIED (data export finished, artboard links ST9)",
      subject: "Your SimpleFit data is ready to download",
      preheader: "Available for 7 days. You’ll need to sign in to download.",
      required_variables: [
        "requested_on",
        "file_name",
        "size",
        "includes",
        "formats",
        "expires_on",
        "download_url",
        "security_url"
      ],
      optional_variables: [],
      primary_cta: "Download my data → download_url",
      fallback_url: "The plain-text part carries both URLs; the design shows no other fallback",
      artboard: "EmailExportReady.dc.html",
      delivery_owner: @delivery,
      status: @implemented_deferred,
      template: :data_export_ready,
      module: SimpleFit.Email.Templates.DataExportReady,
      trigger_owner: "NOT_SPECIFIED (no ticket yet: data-export generation and storage)"
    }
  ]

  @doc "Design source of the inventory."
  @spec source() :: %{artifact: String.t(), version: String.t(), section: String.t()}
  def source, do: %{artifact: @artifact, version: @version, section: @section}

  @doc "All designed emails, E01..E16, in design order."
  @spec entries() :: [map()]
  def entries, do: @entries

  @doc "The allowed statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The entries that have a production template."
  @spec implemented() :: [map()]
  def implemented, do: Enum.filter(@entries, &Map.has_key?(&1, :template))
end
