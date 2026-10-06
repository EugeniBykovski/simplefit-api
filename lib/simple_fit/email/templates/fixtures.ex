defmodule SimpleFit.Email.Templates.Fixtures do
  @moduledoc """
  Deterministic sample variables for every implemented template (ADR 0011).

  Used by the development preview (`/dev/emails`) and by tests. The values
  mirror the Claude Design artboards' sample data (Version 63), use the
  reserved `.example` domain and carry no real credential. Each default
  fixture shows every optional block; `variants/1` names the optional
  states worth previewing.
  """

  @app "https://app.simplefit.example"
  @site "https://simplefit.example"

  @fixtures %{
    verify_email: %{
      code: "407193",
      verify_url: "#{@app}/signup/verify?token=FIXTURE-ONE-TIME-TOKEN",
      expires_in_minutes: 10
    },
    recover_account: %{
      recovery_url: "#{@app}/recover?token=FIXTURE-ONE-TIME-TOKEN",
      expires_in_minutes: 15
    },
    gym_setup: %{
      gym_name: "Simple Boxing Gym",
      continue_url: "#{@app}/gym/setup",
      progress_completed: 3,
      progress_total: 14
    },
    new_sign_in: %{
      signed_in_at: "Oct 1, 21:14 CEST",
      security_url: "#{@app}/settings/security"
    },
    deletion_scheduled: %{
      requested_on: ~D[2026-10-04],
      deletion_on: ~D[2026-11-03],
      restore_url: "#{@app}/settings",
      data_download_url: "#{@app}/settings/data",
      retained_gym_payments: true
    },
    account_deleted: %{
      name: "Karol",
      requested_on: ~D[2026-10-02],
      site_url: @site,
      retained_gym_payments: true
    },
    welcome_fighter: %{
      first_name: "Yauheni",
      camp_weeks: 10,
      camp_ends_on: ~D[2026-11-03],
      first_class_time: "18:00 today",
      first_class_name: "Technical boxing",
      gym_name: "Warsaw Boxing Club",
      first_class_room: "Ring 2",
      first_class_bring: "gloves 14 oz, wraps, mouthguard",
      next_class_hint: "Tue 19:30 pads has 4 spots left.",
      app_url: @app,
      preferences_url: "#{@app}/settings/notifications",
      unsubscribe_url: "#{@app}/email/unsubscribe?token=FIXTURE-UNSUBSCRIBE-TOKEN"
    },
    welcome_coach: %{
      coaching_name: "Yauheni Coaching",
      invite_url: "https://sfit.example/c/yauheni",
      identity_check_pending: true,
      licence_review_pending: true,
      payouts_url: "#{@app}/coach/payouts"
    },
    gym_live: %{
      gym_name: "Simple Boxing Gym",
      published_on: ~D[2026-10-03],
      city: "Warsaw",
      payout_day: "Monday",
      public_page_url: "https://sfit.example/simple-boxing",
      locations: ["Praga", "Wola", "Mokotów"],
      member_invites: "175 · tomorrow 10:00",
      verification_status: "Proof of address in review",
      dashboard_url: "#{@app}/gym/dashboard"
    },
    staff_invite: %{
      invitee_name: "Natalia",
      inviter_name: "Yauheni",
      inviter_display_name: "Yauheni B.",
      inviter_role: "owner",
      gym_name: "Simple Boxing Gym",
      role: "Front desk",
      location: "Praga",
      permissions: [
        "Check members in with their QR",
        "See today’s classes and rosters",
        "Sell drop-ins and passes",
        "Log incidents for the owner"
      ],
      accept_url: "#{@app}/invite/staff?token=FIXTURE-INVITATION-TOKEN",
      expires_on: ~D[2026-10-10]
    },
    member_invite: %{
      member_name: "Marta",
      gym_name: "Simple Boxing Gym",
      plan: "Unlimited",
      active_until: ~D[2026-10-31],
      home_location: "Wola",
      claim_url: "#{@app}/invite/member?token=FIXTURE-INVITATION-TOKEN",
      opt_out_url: "#{@app}/invite/member/opt-out?token=FIXTURE-INVITATION-TOKEN"
    },
    coach_invite: %{
      fighter_name: "Oleg",
      coach_name: "Yauheni",
      coach_initials: "YB",
      coaching_name: "Yauheni Coaching",
      coach_tagline: "Technique & fight camps · Warsaw BC",
      message:
        "Saw you at Saturday sparring — I’d like to run your next camp. Join and I’ll set up the first two weeks.",
      join_url: "#{@app}/invite/coach?token=FIXTURE-INVITATION-TOKEN"
    },
    join_approved: %{
      gym_name: "Warsaw Boxing Club",
      staff_name: "Natalia",
      plan: "Monthly · unlimited classes",
      next_billing: "Nov 1 · €79 · Visa •• 4242",
      booked: "Tue 19:30 Pads · Ring 1",
      notice_days: 30,
      checkin_url: "#{@app}/membership"
    },
    first_week_recap: %{
      first_name: "Yauheni",
      trainings: 4,
      rounds: 52,
      partners: 2,
      board_items: ["Warsaw Boxing Club", "Legia Fight", "roadwork with Alex"],
      challenge_name: "100 rounds in October",
      challenge_rank: 2,
      challenge_participants: 48,
      rival_name: "Mike",
      rival_rounds_ahead: 8,
      board_url: "#{@app}/board",
      preferences_url: "#{@app}/settings/notifications",
      unsubscribe_url: "#{@app}/email/unsubscribe?token=FIXTURE-UNSUBSCRIBE-TOKEN"
    },
    account_suspended: %{
      name: "Tom",
      case_id: "RPT-20938",
      suspended_until: ~D[2026-10-18],
      content_kind: "comments",
      posted_on: ~D[2026-09-30],
      rule: "§3.2 · No insults or threats",
      content_removed: "4 comments",
      suspension: "14 days · ends Oct 18, 12:41",
      previous_notices: "1 warning · Aug 14",
      appeal_url: "#{@app}/appeal?case=RPT-20938"
    },
    data_export_ready: %{
      requested_on: ~D[2026-10-03],
      file_name: "simplefit-yauheni-2026-10-03.zip",
      size: "842 MB",
      includes: "Trainings, Board, messages, videos",
      formats: "JSON + CSV + MP4",
      expires_on: ~D[2026-10-10],
      available_days: 7,
      download_url: "#{@app}/settings/data/export",
      security_url: "#{@app}/settings/security"
    }
  }

  # Named optional states: keys to drop and values to change, applied to the
  # default fixture.
  @variants %{
    welcome_fighter: %{
      "no-camp" => {[:camp_weeks, :camp_ends_on], %{}},
      "no-class" =>
        {[:first_class_time, :first_class_name, :gym_name, :first_class_room, :first_class_bring],
         %{}},
      "minimal" =>
        {[
           :camp_weeks,
           :camp_ends_on,
           :first_class_time,
           :first_class_name,
           :gym_name,
           :first_class_room,
           :first_class_bring,
           :next_class_hint
         ], %{}}
    },
    welcome_coach: %{
      "identity-only" => {[], %{licence_review_pending: false}},
      "licence-only" => {[:payouts_url], %{identity_check_pending: false}},
      "nothing-pending" =>
        {[:payouts_url], %{identity_check_pending: false, licence_review_pending: false}}
    },
    gym_setup: %{"no-progress" => {[:progress_completed, :progress_total], %{}}},
    gym_live: %{
      "no-verification" => {[:verification_status], %{}},
      "minimal" => {[:member_invites, :verification_status], %{}}
    },
    member_invite: %{
      "no-home-location" => {[:home_location], %{}},
      "minimal" => {[:active_until, :home_location], %{}}
    },
    coach_invite: %{"no-note-no-tagline" => {[:message, :coach_tagline], %{}}},
    join_approved: %{
      "no-booking" => {[:booked], %{}},
      "minimal" => {[:next_billing, :booked], %{}}
    },
    first_week_recap: %{
      "no-rival" => {[:rival_name, :rival_rounds_ahead], %{}},
      "no-challenge" =>
        {[
           :challenge_name,
           :challenge_rank,
           :challenge_participants,
           :rival_name,
           :rival_rounds_ahead
         ], %{}}
    },
    account_suspended: %{
      "no-previous-notices" => {[:previous_notices], %{}},
      "minimal" => {[:content_removed, :previous_notices], %{}}
    },
    deletion_scheduled: %{"no-retained-payments" => {[:retained_gym_payments], %{}}},
    account_deleted: %{"no-retained-payments" => {[:retained_gym_payments], %{}}}
  }

  @doc "Sample variables for `template`, with every optional block."
  @spec for_template(atom()) :: map()
  def for_template(template), do: Map.fetch!(@fixtures, template)

  @doc "The named optional-state variants of `template`, sorted."
  @spec variants(atom()) :: [String.t()]
  def variants(template), do: @variants |> Map.get(template, %{}) |> Map.keys() |> Enum.sort()

  @doc "Sample variables for a named variant of `template`, or `:error`."
  @spec for_variant(atom(), String.t()) :: {:ok, map()} | :error
  def for_variant(template, name) do
    with {:ok, {drop, put}} <- @variants |> Map.get(template, %{}) |> Map.fetch(name) do
      {:ok, template |> for_template() |> Map.drop(drop) |> Map.merge(put)}
    end
  end
end
