defmodule SimpleFit.Email.Templates.Inventory do
  @moduledoc """
  Every email designed in Claude Design, page Public Website, section
  "14 · Email templates · after registration" (ADR 0011), Version 63.

  This is the traceability record between production templates and their
  artboards: subject, preheader (or its variants), the renderer's required
  and optional presentation variables, the conditional blocks those
  optional variables control, the CTA, the artboard and the status. A field
  the design does not define is `"NOT_SPECIFIED"`. `deferred` lists the
  product questions a template leaves to the domain that will send it.

  Statuses:

    * `"IMPLEMENTED_TEMPLATE / TRIGGER_AVAILABLE"`
    * `"IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED"`
    * `"DESIGN_ONLY / DOMAIN_NOT_AVAILABLE"`
    * `"AMBIGUOUS / NEEDS_PRODUCT_DECISION"`
  """

  @artifact "https://claude.ai/artifact/JEsBg51MjX8KiHWEro8omY"
  @version "1791284501-e3ff"
  @version_number 63
  @section "Public Website · 14 · Email templates · after registration"
  @delivery "simplefit-api · SimpleFit.Email (Oban mailers queue)"

  @implemented_deferred "IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED"

  @statuses [
    "IMPLEMENTED_TEMPLATE / TRIGGER_AVAILABLE",
    @implemented_deferred,
    "DESIGN_ONLY / DOMAIN_NOT_AVAILABLE",
    "AMBIGUOUS / NEEDS_PRODUCT_DECISION"
  ]

  @plain_text_fallback "The plain-text part carries the full URL; the design shows no other fallback"
  @security_destination "The security URL’s destination (account security settings) still shows future security concepts; it is not part of SF-35 and needs SF-28 / security reconciliation."

  @entries [
             %{
               id: "E01",
               name: "Verify your email",
               trigger: "Email sign-up: confirm the address with a code",
               subject: "Your SimpleFit code: {code}",
               preheader: "Enter it in the app to confirm your email.",
               required_variables: ["code", "verify_url", "expires_in_minutes"],
               optional_variables: [],
               conditional_blocks: [],
               primary_cta: "Verify email → verify_url",
               fallback_url:
                 "The 6-digit code is the alternative to the link; the plain-text part carries the full URL",
               artboard: "project/EmailVerify.dc.html",
               template: :verify_email,
               module: SimpleFit.Email.Templates.VerifyEmail,
               trigger_owner: "SF-21",
               deferred: [
                 "SF-21 owns verification and decides whether both the link and the code are supported; it reconciles the template if not."
               ]
             },
             %{
               id: "E02",
               name: "Welcome, fighter",
               trigger: "After fighter registration (artboard links F01)",
               subject: "You’re in, {first_name} — here’s your first week",
               preheader: [
                 "class + camp: Your class, your camp and the round timer are set.",
                 "class only: Your class and the round timer are set.",
                 "camp only: Your camp and the round timer are set.",
                 "neither: The round timer is set."
               ],
               required_variables: ["first_name", "app_url", "preferences_url", "unsubscribe_url"],
               optional_variables: [
                 "camp_weeks",
                 "camp_ends_on",
                 "first_class_time",
                 "first_class_name",
                 "gym_name",
                 "first_class_room",
                 "first_class_bring",
                 "next_class_hint"
               ],
               conditional_blocks: [
                 "camp end sentence (camp_weeks + camp_ends_on)",
                 "FIRST CLASS card (first_class_time, first_class_name, gym_name, first_class_room, first_class_bring)",
                 "next-class hint under step 1 (next_class_hint)",
                 "preheader variant (class, camp)"
               ],
               primary_cta: "Open SimpleFit → app_url",
               fallback_url:
                 "The plain-text part carries every URL; Email preferences and Unsubscribe URLs are presentation data (no preference system exists)",
               artboard: "project/EmailWelcomeFighter.dc.html",
               template: :welcome_fighter,
               module: SimpleFit.Email.Templates.WelcomeFighter,
               trigger_owner: "Future fighter onboarding ticket (not yet created)",
               deferred: [
                 "“weight and RPE never leave your phone” may conflict with coach-visible metrics shared with consent (E08); the Fighter/Coach domain must reconcile it.",
                 "Email preferences and Unsubscribe destinations do not exist yet."
               ]
             },
             %{
               id: "E03",
               name: "Welcome, coach",
               trigger: "After coach registration (artboard links OC5)",
               subject: "Your coaching space is ready",
               preheader: [
                 "identity check + licence review: Invite fighters, finish payouts, get your verified badge.",
                 "identity check only: Invite fighters and finish payouts.",
                 "licence review only: Invite fighters and get your verified badge.",
                 "neither: Invite fighters with your link."
               ],
               required_variables: [
                 "coaching_name",
                 "invite_url",
                 "identity_check_pending",
                 "licence_review_pending"
               ],
               # payouts_url is required while identity_check_pending, `:unexpected` otherwise.
               optional_variables: ["payouts_url"],
               conditional_blocks: [
                 "“Here’s what’s left:” lead-in and the numbered remaining actions (any pending)",
                 "identity check step (identity_check_pending)",
                 "licence review step (licence_review_pending)",
                 "Finish payouts button (identity_check_pending)",
                 "preheader variant (identity check, licence review)"
               ],
               primary_cta:
                 "Finish payouts → payouts_url, only while the identity check is pending; none otherwise",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailWelcomeCoach.dc.html",
               template: :welcome_coach,
               module: SimpleFit.Email.Templates.WelcomeCoach,
               trigger_owner: "Future coach onboarding ticket (not yet created)",
               deferred: [
                 "With nothing pending there is no primary button; the Coach domain may later decide whether a fallback CTA is wanted."
               ]
             },
             %{
               id: "E04",
               name: "Finish gym setup",
               trigger: "Gym owner has an unfinished gym setup (artboard links OG1)",
               subject: "Finish setting up {gym_name}",
               preheader: "Pick up where you left off — about 20 minutes on a computer.",
               required_variables: ["gym_name", "continue_url"],
               optional_variables: ["progress_completed", "progress_total"],
               conditional_blocks: [
                 "“· {completed} OF {total} DONE” in the eyebrow and the segmented progress bar (progress_completed + progress_total)"
               ],
               primary_cta:
                 "Continue setup → continue_url (navigation only: the email does not sign anyone in)",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailWelcomeGym.dc.html",
               template: :gym_setup,
               module: SimpleFit.Email.Templates.GymSetup,
               trigger_owner: "Future gym onboarding ticket (not yet created)",
               deferred: [
                 "The Gym onboarding domain owns setup steps, their count and resume state."
               ]
             },
             %{
               id: "E05",
               name: "Your gym is live",
               trigger: "Gym published (artboard links WG1)",
               subject: "{gym_name} is live",
               preheader: "Members can find you, book and pay from today.",
               required_variables: [
                 "gym_name",
                 "published_on",
                 "city",
                 "payout_day",
                 "public_page_url",
                 "locations",
                 "dashboard_url"
               ],
               optional_variables: ["member_invites", "verification_status"],
               conditional_blocks: [
                 "Member invites row (member_invites)",
                 "Verification row (verification_status)"
               ],
               primary_cta: "Open dashboard → dashboard_url",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailGymLive.dc.html",
               template: :gym_live,
               module: SimpleFit.Email.Templates.GymLive,
               trigger_owner: "Future gym publishing ticket (not yet created)",
               deferred: [
                 "“codes rotate so they can’t be shared” (check-in QR) must be confirmed by the future Gym/check-in domain; SF-35 implements no QR rotation."
               ]
             },
             %{
               id: "E06",
               name: "Staff invitation",
               trigger: "Gym owner invites staff (artboard links OS1)",
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
               conditional_blocks: [],
               primary_cta: "Accept invitation → accept_url",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailStaffInvite.dc.html",
               template: :staff_invite,
               module: SimpleFit.Email.Templates.StaffInvite,
               trigger_owner: "Future gym staff ticket (not yet created)",
               deferred: []
             },
             %{
               id: "E07",
               name: "Member invite from gym",
               trigger: "Gym imports its members (artboard links A03)",
               subject: "{gym_name} is now on SimpleFit",
               preheader: "Claim your {plan} membership — book and check in from your phone.",
               required_variables: ["member_name", "gym_name", "plan", "claim_url", "opt_out_url"],
               optional_variables: ["active_until", "home_location"],
               conditional_blocks: [
                 "Active until row (active_until)",
                 "Home location row (home_location)"
               ],
               primary_cta: "Claim my membership → claim_url",
               fallback_url:
                 "The plain-text part carries both URLs; the opt-out URL is presentation data (no opt-out flow exists)",
               artboard: "project/EmailMemberInvite.dc.html",
               template: :member_invite,
               module: SimpleFit.Email.Templates.MemberInvite,
               trigger_owner: "Future membership import ticket (not yet created)",
               deferred: [
                 "The privacy note says the gym shared name, email and plan; the future membership/import domain must confirm what an import really shares."
               ]
             },
             %{
               id: "E08",
               name: "Coach invited you",
               trigger: "Coach invites a fighter (artboard links A03)",
               subject: "{coach_name} invited you to train with {coaching_name}",
               preheader: "Join {coach_name}’s team on SimpleFit — your log stays yours.",
               required_variables: [
                 "fighter_name",
                 "coach_name",
                 "coach_initials",
                 "coaching_name",
                 "join_url"
               ],
               optional_variables: ["coach_tagline", "message"],
               conditional_blocks: [
                 "tagline under the coaching name (coach_tagline)",
                 "quoted personal note, escaped plain text (message)"
               ],
               primary_cta: "Join {coach_name}’s team → join_url",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailCoachInvite.dc.html",
               template: :coach_invite,
               module: SimpleFit.Email.Templates.CoachInvite,
               trigger_owner: "Future coaching ticket (not yet created)",
               deferred: []
             },
             %{
               id: "E09",
               name: "Join request approved",
               trigger: "Gym front desk confirms a membership (artboard links F16)",
               subject: "You’re in at {gym_name}",
               preheader: "Your membership is confirmed — check in with your phone.",
               required_variables: [
                 "gym_name",
                 "staff_name",
                 "plan",
                 "notice_days",
                 "checkin_url"
               ],
               optional_variables: ["next_billing", "booked"],
               conditional_blocks: [
                 "Next billing row (next_billing, recurring plans)",
                 "Booked row (booked)"
               ],
               primary_cta: "Show my check-in QR → checkin_url",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailJoinApproved.dc.html",
               template: :join_approved,
               module: SimpleFit.Email.Templates.JoinApproved,
               trigger_owner: "Future membership ticket (not yet created)",
               deferred: [
                 "The copy describes a front-desk confirmation; online join flows may need their own copy or variant."
               ]
             },
             %{
               id: "E10",
               name: "New sign-in alert",
               trigger: "A new sign-in to the account (detection owned by security work)",
               subject: "New sign-in to your SimpleFit account",
               preheader: "If this was you, no action is needed.",
               required_variables: ["signed_in_at", "security_url"],
               optional_variables: [],
               conditional_blocks: [],
               primary_cta: "Secure my account → security_url",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailNewSignIn.dc.html",
               template: :new_sign_in,
               module: SimpleFit.Email.Templates.NewSignIn,
               trigger_owner: "SF-28 / security reconciliation (expected)",
               deferred: [
                 "What counts as a new sign-in is undecided; nothing detects it today.",
                 @security_destination
               ]
             },
             %{
               id: "E11",
               name: "Recover account",
               trigger: "Account recovery requested",
               subject: "Recover your SimpleFit account",
               preheader: "Use this link within {expires_in_minutes} minutes.",
               required_variables: ["recovery_url", "expires_in_minutes"],
               optional_variables: [],
               conditional_blocks: [],
               primary_cta: "Recover my account → recovery_url",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailRecover.dc.html",
               template: :recover_account,
               module: SimpleFit.Email.Templates.RecoverAccount,
               trigger_owner: "SF-28 (expected)",
               deferred: [
                 "The displayed lifetime is presentation data; SF-28 owns the recovery credential and its real lifetime.",
                 @security_destination
               ]
             },
             %{
               id: "E12",
               name: "First week recap",
               trigger: "Weekly recap after the first week (artboard links B21; product email)",
               subject: "Your first week: {trainings} trainings, {rounds} rounds",
               preheader: [
                 "with rival: Your Board has its first nodes — and {rival_name} is {rival_rounds_ahead} rounds ahead.",
                 "without rival: Your Board has its first nodes."
               ],
               required_variables: [
                 "first_name",
                 "trainings",
                 "rounds",
                 "partners",
                 "board_items",
                 "board_url",
                 "preferences_url",
                 "unsubscribe_url"
               ],
               optional_variables: [
                 "challenge_name",
                 "challenge_rank",
                 "challenge_participants",
                 "rival_name",
                 "rival_rounds_ahead"
               ],
               conditional_blocks: [
                 "Gym challenge sentence (challenge_name + challenge_rank + challenge_participants)",
                 "rival-ahead line in the sentence and the preheader (rival_name + rival_rounds_ahead, only with a challenge)"
               ],
               primary_cta: "See your Board → board_url",
               fallback_url:
                 "The plain-text part carries every URL; Email preferences and Unsubscribe URLs are presentation data (no preference system exists)",
               artboard: "project/EmailWeek1.dc.html",
               template: :first_week_recap,
               module: SimpleFit.Email.Templates.FirstWeekRecap,
               trigger_owner: "Future training recap ticket (not yet created)",
               deferred: ["Email preferences and Unsubscribe destinations do not exist yet."]
             },
             %{
               id: "E13",
               name: "Account suspended",
               trigger: "Moderation suspends an account (artboard links ST15)",
               subject: "Your SimpleFit account is suspended until {suspended_until}",
               preheader: "Why, what still works, and how to appeal.",
               required_variables: [
                 "name",
                 "case_id",
                 "suspended_until",
                 "content_kind",
                 "posted_on",
                 "rule",
                 "suspension",
                 "appeal_url"
               ],
               optional_variables: ["content_removed", "previous_notices"],
               conditional_blocks: [
                 "Content removed row (content_removed)",
                 "Previous notices row (previous_notices)"
               ],
               primary_cta: "Appeal this decision → appeal_url",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailSuspended.dc.html",
               template: :account_suspended,
               module: SimpleFit.Email.Templates.AccountSuspended,
               trigger_owner: "Future moderation ticket (not yet created)",
               deferred: []
             },
             %{
               id: "E14",
               name: "Deletion scheduled",
               trigger: "Account deletion requested",
               subject: "Your account will be deleted on {deletion_on}",
               preheader: "Changed your mind? You can restore it before then.",
               required_variables: [
                 "requested_on",
                 "deletion_on",
                 "restore_url",
                 "data_download_url"
               ],
               optional_variables: ["retained_gym_payments"],
               conditional_blocks: [
                 "“We keep · anonymised” section (retained_gym_payments: true)"
               ],
               primary_cta: "Restore my account → restore_url",
               fallback_url:
                 "The plain-text part carries both URLs; the design shows no other fallback",
               artboard: "project/EmailDeleteScheduled.dc.html",
               template: :deletion_scheduled,
               module: SimpleFit.Email.Templates.DeletionScheduled,
               trigger_owner: "SF-28 (expected)",
               deferred: ["The deletion lifecycle owns the restore workflow and retention rules."]
             },
             %{
               id: "E15",
               name: "Account deleted",
               trigger: "Account permanently deleted",
               subject: "Your SimpleFit account has been deleted",
               preheader: "This is the last email we’ll send you.",
               required_variables: ["name", "requested_on", "site_url"],
               optional_variables: ["retained_gym_payments"],
               conditional_blocks: ["“Kept · anonymised” row (retained_gym_payments: true)"],
               primary_cta: "Visit SimpleFit → site_url",
               fallback_url: @plain_text_fallback,
               artboard: "project/EmailDeleted.dc.html",
               template: :account_deleted,
               module: SimpleFit.Email.Templates.AccountDeleted,
               trigger_owner: "SF-28 (expected)",
               deferred: []
             },
             %{
               id: "E16",
               name: "Data export ready",
               trigger: "Requested data export finished (artboard links ST9)",
               subject: "Your SimpleFit data is ready to download",
               preheader: "Available for {available_days} days.",
               required_variables: [
                 "requested_on",
                 "file_name",
                 "size",
                 "includes",
                 "formats",
                 "expires_on",
                 "available_days",
                 "download_url",
                 "security_url"
               ],
               optional_variables: [],
               conditional_blocks: [],
               primary_cta: "Download my data → download_url",
               fallback_url:
                 "The plain-text part carries both URLs; the design shows no other fallback",
               artboard: "project/EmailExportReady.dc.html",
               template: :data_export_ready,
               module: SimpleFit.Email.Templates.DataExportReady,
               trigger_owner: "Future data export ticket (not yet created)",
               deferred: [
                 "The export domain owns generation, storage, download authorization and the real expiry; the displayed dates are presentation data.",
                 @security_destination
               ]
             }
           ]
           |> Enum.map(
             &Map.merge(&1, %{delivery_owner: @delivery, status: @implemented_deferred})
           )

  @doc "Design source of the inventory."
  @spec source() :: %{
          artifact: String.t(),
          version: String.t(),
          version_number: pos_integer(),
          section: String.t()
        }
  def source,
    do: %{
      artifact: @artifact,
      version: @version,
      version_number: @version_number,
      section: @section
    }

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
