defmodule SimpleFit.Email.TemplatesTest do
  # Not async: some tests change template configuration in the app env.
  use SimpleFit.DataCase, async: false
  use Oban.Testing, repo: SimpleFit.Repo

  import ExUnit.CaptureLog

  alias SimpleFit.Email
  alias SimpleFit.Email.{DeliveryWorker, JobPayload, Message}
  alias SimpleFit.Email.Templates
  alias SimpleFit.Email.Templates.{Fixtures, Inventory, Rendered}

  @inventory_fields [
    :id,
    :name,
    :trigger,
    :subject,
    :preheader,
    :required_variables,
    :optional_variables,
    :conditional_blocks,
    :primary_cta,
    :fallback_url,
    :artboard,
    :delivery_owner,
    :status,
    :trigger_owner
  ]

  @footers %{
    security: "This is a security email. You can’t unsubscribe from security emails.",
    activity: "You’re receiving this because of activity on your SimpleFit account.",
    invitation:
      "Someone invited this address. If you weren’t expecting it, ignore this email — no account is created.",
    member: "You get this because you’re a SimpleFit member."
  }

  @footer_of %{
    verify_email: :security,
    welcome_fighter: :member,
    welcome_coach: :activity,
    gym_setup: :activity,
    gym_live: :activity,
    staff_invite: :invitation,
    member_invite: :invitation,
    coach_invite: :invitation,
    join_approved: :activity,
    new_sign_in: :security,
    recover_account: :security,
    first_week_recap: :member,
    account_suspended: :security,
    deletion_scheduled: :security,
    account_deleted: :security,
    data_export_ready: :security,
    sign_in_code: :security
  }

  # Fields whose format is stricter than a display line (codes, enums).
  @strict_fields [:code, :case_id, :coach_initials, :payout_day]

  defp render(template, overrides \\ %{}) do
    apply(Templates, template, [Map.merge(Fixtures.for_template(template), overrides)])
  end

  defp rendered!(template) do
    {:ok, %Rendered{} = rendered} = render(template)
    rendered
  end

  defp variant!(template, name) do
    {:ok, attrs} = Fixtures.for_variant(template, name)
    {:ok, %Rendered{} = rendered} = apply(Templates, template, [attrs])
    rendered
  end

  defp without(template, keys) do
    apply(Templates, template, [Map.drop(Fixtures.for_template(template), keys)])
  end

  # Every default fixture and every named optional state.
  defp all_states do
    for %{template: template} <- Inventory.implemented(),
        state <- [nil | Fixtures.variants(template)] do
      {template, state, if(state, do: variant!(template, state), else: rendered!(template))}
    end
  end

  # Label/value tables draw a divider under every row but the last.
  defp dividers(html), do: length(String.split(html, "border-bottom: 1px solid #DCDDD3;")) - 1

  defp with_template_config(config) do
    original = Application.get_env(:simple_fit, Templates)
    Application.put_env(:simple_fit, Templates, config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:simple_fit, Templates, original),
        else: Application.delete_env(:simple_fit, Templates)
    end)
  end

  describe "inventory and design traceability" do
    test "covers every designed email E01..E17 exactly once, in design order" do
      ids = Enum.map(Inventory.entries(), & &1.id)
      assert ids == Enum.map(1..17, &("E" <> String.pad_leading(Integer.to_string(&1), 2, "0")))
    end

    test "records the design source and version" do
      assert %{
               artifact: "https://claude.ai/artifact/JEsBg51MjX8KiHWEro8omY",
               version: "1791292422-dc85",
               version_number: 66,
               section: "Public Website · 14 · Email templates · after registration"
             } = Inventory.source()
    end

    test "every entry has every product field and an explicit status" do
      for entry <- Inventory.entries(), field <- @inventory_fields do
        value = Map.fetch!(entry, field)
        assert value not in [nil, ""], "#{entry.id} is missing #{field}"
      end

      for entry <- Inventory.entries() do
        assert entry.status in Inventory.statuses()
        assert entry.artboard =~ ~r/\Aproject\/Email[A-Za-z0-9]+\.dc\.html\z/
        assert is_list(entry.optional_variables)
        assert is_list(entry.conditional_blocks)
        assert is_list(entry.deferred)
      end
    end

    test "every implemented template maps to its artboard, module and trigger owner" do
      implemented = Inventory.implemented()

      assert Enum.map(implemented, & &1.id) == Enum.map(Inventory.entries(), & &1.id)
      assert length(implemented) == 17

      assert Map.keys(@footer_of) |> Enum.sort() ==
               implemented |> Enum.map(& &1.template) |> Enum.sort()

      # SF-21 wires the triggers of E01 and E17; every other trigger is deferred.
      for entry <- implemented do
        expected =
          if entry.id in ["E01", "E17"],
            do: "IMPLEMENTED_TEMPLATE / TRIGGER_AVAILABLE",
            else: "IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED"

        assert entry.status == expected
        assert Code.ensure_loaded?(entry.module)
        assert function_exported?(Templates, entry.template, 1)
        assert is_list(entry.required_variables)
        assert is_binary(entry.trigger_owner)

        # The declared variables are exactly what the full fixture supplies.
        assert (entry.required_variables ++ entry.optional_variables) |> Enum.sort() ==
                 Fixtures.for_template(entry.template)
                 |> Map.keys()
                 |> Enum.map(&Atom.to_string/1)
                 |> Enum.sort()
      end
    end

    test "optional variables are really optional: the template renders without all of them" do
      for %{template: template, optional_variables: optional} <- Inventory.implemented(),
          optional != [] do
        keys = Enum.map(optional, &String.to_existing_atom/1)
        attrs = Map.drop(Fixtures.for_template(template), keys)

        # E03: without the identity check pending there is no payouts URL.
        attrs =
          if template == :welcome_coach,
            do: Map.put(attrs, :identity_check_pending, false),
            else: attrs

        assert {:ok, %Rendered{}} = apply(Templates, template, [attrs]), "#{template}"
      end
    end

    test "renderers take presentation data only: no Repo, schema or query" do
      for %{module: module} <- Inventory.implemented() do
        source = File.read!(module.module_info(:compile)[:source])
        refute source =~ ~r/Repo|Ecto\.Schema|Ecto\.Query|SimpleFit\.Accounts/
      end
    end

    test "is documented in ADR 0011" do
      adr = File.read!("docs/architecture/adr/0011-transactional-email-templates.md")
      for entry <- Inventory.entries(), do: assert(adr =~ entry.id)
      assert adr =~ "1791292422-dc85"
      refute adr =~ "AMBIGUOUS / NEEDS_PRODUCT_DECISION |"
      refute adr =~ "coach_possessive"
    end
  end

  describe "rendering" do
    test "E01 verify email (Version 66)" do
      r = rendered!(:verify_email)

      assert r.subject == "Your SimpleFit verification code: 407193"
      assert r.preheader == "Enter it where you’re signing up to verify your email."
      assert r.html =~ "Verify your email</h1>"
      assert r.text =~ "Enter this code where you’re signing up to finish creating your account."
      assert r.html =~ "407 193"
      assert r.html =~ "Expires in 10 minutes"
      assert r.text =~ "Or verify with this link:"

      assert r.html =~
               ~s(href="https://app.simplefit.example/verify-email#token=FIXTURE-ONE-TIME-TOKEN")

      assert r.html =~ ">Verify email</a>"

      assert r.text =~
               "Verify email:\nhttps://app.simplefit.example/verify-email#token=FIXTURE-ONE-TIME-TOKEN"

      assert r.text =~
               "The link and the code do the same thing: they verify this email address. Opening the link doesn’t sign you in."

      assert r.text =~ "Didn’t try to sign up? You can ignore this email."

      for stale <- ["Confirm your email", "one tap", "in the app", "no account is created"] do
        refute r.html <> r.text =~ stale
      end
    end

    test "E17 sign-in code (Version 66)" do
      r = rendered!(:sign_in_code)

      assert r.subject == "Your SimpleFit sign-in code: 528461"
      assert r.preheader == "It expires in 10 minutes. Never share it."
      assert r.html =~ ">SIGN IN</td>"
      assert r.html =~ "Your sign-in code</h1>"
      assert r.text =~ "Enter this code where you asked to sign in to SimpleFit."
      assert r.html =~ "528 461"
      assert r.html =~ "Expires in 10 minutes"
      assert r.text =~ "Never share this code. SimpleFit staff will never ask you for it."

      assert r.text =~
               "Didn’t try to sign in? You can ignore this email — someone may have typed your address by mistake."

      # Code only: no link of any kind besides the footer's static text.
      refute r.html =~ "<a href"
      refute r.text =~ "http"

      {:ok, one} = render(:sign_in_code, %{expires_in_minutes: 1})
      assert one.preheader == "It expires in 1 minute. Never share it."

      for bad <- ["12345", "1234567", "12a456", " 123456"] do
        assert {:error, {:invalid_template_data, [code: :invalid_format]}} =
                 render(:sign_in_code, %{code: bad})
      end
    end

    test "E04 finish gym setup: a navigation link, never a sign-in link" do
      r = rendered!(:gym_setup)

      assert r.subject == "Finish setting up Simple Boxing Gym"
      assert r.preheader == "Pick up where you left off — about 20 minutes on a computer."
      assert r.html =~ ">GYM SETUP · 3 OF 14 DONE</p>"
      assert r.html =~ "Let’s get Simple Boxing Gym live.</h1>"
      assert r.html =~ ~s(aria-label="3 of 14 done")
      assert length(String.split(r.html, "bgcolor=\"#5B6524\"")) - 1 == 3
      assert length(String.split(r.html, "bgcolor=\"#D6D8CB\"")) - 1 == 11

      assert r.text =~
               "If you’re not signed in, you’ll sign in as usual and go straight back to your setup."

      assert r.text =~ "Continue setup:\nhttps://app.simplefit.example/gym/setup"
      assert r.text =~ "- A CSV export of current members (optional)"

      for claim <- [
            "signs you in",
            "valid for 24 hours",
            "setup call",
            "Gym Success",
            "secure setup link"
          ] do
        refute r.html <> r.text =~ claim
      end
    end

    test "E04 progress is optional and must be coherent" do
      r = variant!(:gym_setup, "no-progress")
      assert r.html =~ ">GYM SETUP</p>"
      refute r.html =~ "DONE"
      refute r.html =~ "aria-label="
      refute r.text =~ "DONE"

      for {overrides, field, reason} <- [
            {%{progress_total: 0}, :progress_total, :out_of_range},
            {%{progress_total: 31}, :progress_total, :out_of_range},
            {%{progress_completed: -1}, :progress_completed, :out_of_range},
            {%{progress_completed: 14}, :progress_completed, :out_of_range},
            {%{progress_completed: 15}, :progress_completed, :out_of_range}
          ] do
        assert {:error, {:invalid_template_data, errors}} = render(:gym_setup, overrides)
        assert {field, reason} in errors, inspect(overrides)
      end

      assert {:error, {:invalid_template_data, [progress_total: :required]}} =
               without(:gym_setup, [:progress_total])

      assert {:ok, zero} = render(:gym_setup, %{progress_completed: 0, progress_total: 1})
      assert zero.html =~ "GYM SETUP · 0 OF 1 DONE"
    end

    test "E10 new sign-in alert states only the time" do
      r = rendered!(:new_sign_in)

      assert r.subject == "New sign-in to your SimpleFit account"
      assert r.preheader == "If this was you, no action is needed."
      assert r.html =~ ~s(color: #A23F27;">NEW SIGN-IN</p>)
      assert r.text =~ "Time: Oct 1, 21:14 CEST"
      assert r.text =~ "If this was you, no action is needed."
      assert r.text =~ "If you don’t recognize this activity, secure your account."
      assert r.html =~ ~s(bgcolor="#FBE9E4")
      assert r.html =~ "border: 1.5px solid #E07A5F;"
      assert r.text =~ "Secure my account:\nhttps://app.simplefit.example/settings/security"

      for claim <- [
            "Device",
            "Firefox",
            "location",
            "Berlin",
            "Password",
            "authenticator",
            "passkey",
            "sign out every other device",
            "paused for 24 hours",
            "Method"
          ] do
        refute r.html <> r.text =~ claim, claim
      end
    end

    test "E11 recover account: a recovery link only" do
      r = rendered!(:recover_account)

      assert r.subject == "Recover your SimpleFit account"
      assert r.preheader == "Use this link within 15 minutes."
      assert r.html =~ "Recover your account</h1>"

      assert r.text =~
               "We received a request to recover access to your SimpleFit account. This link expires in 15 minutes."

      assert r.html =~ ">Recover my account</a>"

      assert r.text =~
               "Recover my account:\nhttps://app.simplefit.example/recover?token=FIXTURE-ONE-TIME-TOKEN"

      assert r.text =~
               "Someone may have entered your email by mistake. You can ignore this message."

      for claim <- ["passkey", "code", "OR ENTER", "works once", "K7Q-2MX"] do
        refute r.html <> r.text =~ claim, claim
      end

      {:ok, one} = render(:recover_account, %{expires_in_minutes: 1})
      assert one.preheader == "Use this link within 1 minute."

      # The old code input is gone from the contract.
      assert {:ok, _} = render(:recover_account, %{})
      refute "code" in Enum.find(Inventory.entries(), &(&1.id == "E11")).required_variables
    end

    test "E14 deletion scheduled" do
      r = rendered!(:deletion_scheduled)

      assert r.subject == "Your account will be deleted on Nov 3"
      assert r.preheader == "Changed your mind? You can restore it before then."
      assert r.html =~ "Your account will be deleted on Nov 3.</h1>"

      assert r.text =~
               "We received your request on Oct 4 and scheduled your account for deletion. You can restore it any time before then."

      for claim <- ["signed out", "other devices", "profile is hidden", "one tap"] do
        refute r.html <> r.text =~ claim, claim
      end

      assert r.html =~ "ON NOV 3 WE DELETE"
      assert r.html =~ ~s(href="https://app.simplefit.example/settings")
      assert r.html =~ ~s(href="https://app.simplefit.example/settings/data")
      assert r.text =~ "Download your data (https://app.simplefit.example/settings/data)"
      assert r.text =~ "required by Polish accounting law"
    end

    test "E15 account deleted" do
      r = rendered!(:account_deleted)

      assert r.subject == "Your SimpleFit account has been deleted"
      assert r.preheader == "This is the last email we’ll send you."
      assert r.html =~ "Hi Karol. As you asked on Oct 2"
      assert r.html =~ "Removed after this message"
      assert r.text =~ "Kept · anonymised: Gym payments, 5 years (law)"
      assert dividers(r.html) == 2 * 2
      assert r.html =~ ~s(href="https://simplefit.example")
      assert r.text =~ "Visit SimpleFit:\nhttps://simplefit.example"
    end

    test "E02 welcome fighter" do
      r = rendered!(:welcome_fighter)

      assert r.subject == "You’re in, Yauheni — here’s your first week"
      assert r.preheader == "Your class, your camp and the round timer are set."

      assert r.html =~
               "Your 10-week fight camp ends <strong style=\"color: #1A1D1B;\">Tue, Nov 3</strong>"

      assert r.html =~ "18:00 today"
      assert r.html =~ "Technical boxing · Warsaw Boxing Club · Ring 2"

      assert r.html =~
               "Bring gloves 14 oz, wraps, mouthguard. Front desk confirms your membership."

      assert r.html =~ "Tue 19:30 pads has 4 spots left."
      assert r.html =~ ">Open SimpleFit</a>"
      assert r.text =~ "1. Book your next class\n   Tue 19:30 pads has 4 spots left."
      assert r.text =~ "FIRST CLASS\n18:00 today"
    end

    test "E03 welcome coach" do
      r = rendered!(:welcome_coach)

      assert r.subject == "Your coaching space is ready"
      assert r.html =~ "YAUHENI COACHING"
      assert r.html =~ ">sfit.example/c/yauheni</p>"
      assert r.html =~ ~s(href="https://app.simplefit.example/coach/payouts")
      assert r.text =~ "Fighters can now book you and join your team. Here’s what’s left:"
      assert r.text =~ "1. Finish the identity check"
      assert r.text =~ "2. Wait for licence review"
      refute r.html <> r.text =~ "Two things left"
    end

    test "E05 gym live" do
      r = rendered!(:gym_live)

      assert r.subject == "Simple Boxing Gym is live"
      assert r.html =~ "PUBLISHED · OCT 3"

      assert r.html =~
               "You’re in Discover in Warsaw, bookings are open and payments go to your bank every Monday."

      assert r.html =~ "Praga · Wola · Mokotów"
      assert r.text =~ "Public page: sfit.example/simple-boxing"
      assert r.text =~ "Open dashboard:\nhttps://app.simplefit.example/gym/dashboard"
    end

    test "E06 staff invitation" do
      r = rendered!(:staff_invite)

      assert r.subject == "Yauheni invited you to Simple Boxing Gym"
      assert r.preheader == "Join the team as Front desk · Praga."
      assert r.html =~ "Hi Natalia, you’re invited to the team.</h1>"
      assert r.text =~ "Yauheni B. (owner) invited you as Front desk at the Praga location."
      assert r.text =~ "- Log incidents for the owner"
      assert r.text =~ "The invitation expires on Oct 10."
    end

    test "E07 member invite with a presentation-only opt-out URL" do
      r = rendered!(:member_invite)

      assert r.subject == "Simple Boxing Gym is now on SimpleFit"
      assert r.preheader == "Claim your Unlimited membership — book and check in from your phone."
      assert r.text =~ "Active until: Oct 31, 2026"
      assert r.text =~ "✓ Check in with a QR — no card needed"

      assert r.text =~
               "Don’t want this? Opt out (https://app.simplefit.example/invite/member/opt-out?token=FIXTURE-INVITATION-TOKEN) and we delete the invite."

      assert {:error, {:invalid_template_data, [opt_out_url: :invalid_url]}} =
               render(:member_invite, %{opt_out_url: "javascript:alert(1)"})
    end

    test "E08 coach invite renders the coach's message as escaped plain text" do
      r = rendered!(:coach_invite)

      assert r.subject == "Yauheni invited you to train with Yauheni Coaching"
      assert r.preheader == "Join Yauheni’s team on SimpleFit — your log stays yours."
      assert r.html =~ ">YB</div>"
      assert r.html =~ "Technique &amp; fight camps · Warsaw BC"
      assert r.text =~ "“Saw you at Saturday sparring"
      assert r.text =~ "” — Yauheni"
      assert r.html =~ ">Join Yauheni’s team</a>"

      {:ok, hostile} =
        render(:coach_invite, %{message: ~S|<a href="https://evil.example">win</a> & <b>bold</b>|})

      refute hostile.html =~ "evil.example\""
      refute hostile.html =~ "<b>bold"

      assert hostile.html =~
               "&lt;a href=&quot;https://evil.example&quot;&gt;win&lt;/a&gt; &amp; &lt;b&gt;bold&lt;/b&gt;"

      for message <- ["line one\nline two", "x\r\nBcc: a@b.c", String.duplicate("a", 501)] do
        assert {:error, {:invalid_template_data, [message: _]}} =
                 render(:coach_invite, %{message: message})
      end

      # The pronoun input is gone; no gendered copy remains.
      refute "coach_possessive" in Enum.find(Inventory.entries(), &(&1.id == "E08")).optional_variables

      for word <- [" his ", " her ", " their team"] do
        refute r.html <> r.text <> r.preheader =~ word
      end
    end

    test "E09 join approved" do
      r = rendered!(:join_approved)

      assert r.subject == "You’re in at Warsaw Boxing Club"
      assert r.text =~ "Natalia confirmed your membership at the front desk."
      assert r.text =~ "Next billing: Nov 1 · €79 · Visa •• 4242"
      assert r.text =~ "30 days notice, as agreed with the gym."
    end

    test "E12 first week recap" do
      r = rendered!(:first_week_recap)

      assert r.subject == "Your first week: 4 trainings, 52 rounds"
      assert r.preheader == "Your Board has its first nodes — and Mike is 8 rounds ahead."
      assert r.text =~ "4 trainings · 52 rounds · 2 partners"
      assert r.text =~ "Warsaw Boxing Club · Legia Fight · roadwork with Alex"

      assert r.text =~
               "Gym challenge: you’re #2 of 48 in “100 rounds in October”. Mike is 8 rounds ahead."

      {:ok, one} = render(:first_week_recap, %{trainings: 1, rounds: 1, rival_rounds_ahead: 1})
      assert one.subject == "Your first week: 1 training, 1 round"
      assert one.preheader =~ "Mike is 1 round ahead."

      assert {:error, {:invalid_template_data, [challenge_rank: :out_of_range]}} =
               render(:first_week_recap, %{challenge_rank: 49})
    end

    test "E13 account suspended" do
      r = rendered!(:account_suspended)

      assert r.subject == "Your SimpleFit account is suspended until Oct 18"
      assert r.html =~ ~s(color: #A23F27;">CASE RPT-20938</p>)
      assert r.text =~ "Hi Tom. A moderator reviewed reports about comments you posted on Sep 30"
      assert r.text =~ "PAUSED UNTIL OCT 18\n– Comments, posts, invites and messages"

      assert r.text =~
               "Appeal this decision:\nhttps://app.simplefit.example/appeal?case=RPT-20938"

      assert {:error, {:invalid_template_data, [case_id: :invalid_format]}} =
               render(:account_suspended, %{case_id: "rpt 1"})
    end

    test "E16 data export ready" do
      r = rendered!(:data_export_ready)

      assert r.subject == "Your SimpleFit data is ready to download"
      assert r.text =~ "as you requested on Oct 3."
      assert r.text =~ "File: simplefit-yauheni-2026-10-03.zip"
      assert r.text =~ "Expires: Oct 10"
      assert r.preheader == "Available for 7 days."

      assert r.text =~
               "Your export contains personal data — keep the file somewhere safe. Didn’t request this?"

      refute r.html <> r.text =~ "passkey"
      refute r.html <> r.text =~ "sign in"

      {:ok, one} = render(:data_export_ready, %{available_days: 1})
      assert one.preheader == "Available for 1 day."

      assert r.html =~
               ~s(href="https://app.simplefit.example/settings/security" target="_blank" style="color: #A23F27;)

      assert {:error, {:invalid_template_data, [expires_on: :out_of_range]}} =
               render(:data_export_ready, %{expires_on: ~D[2026-10-03]})
    end

    test "member emails link preferences and unsubscribe as presentation data" do
      for template <- [:welcome_fighter, :first_week_recap] do
        r = rendered!(template)
        assert r.html =~ ~s(href="https://app.simplefit.example/settings/notifications")
        assert r.html =~ ">Unsubscribe</a>"

        assert r.text =~
                 "Unsubscribe (https://app.simplefit.example/email/unsubscribe?token=FIXTURE-UNSUBSCRIBE-TOKEN)"

        assert {:error, {:invalid_template_data, [unsubscribe_url: :invalid_url]}} =
                 render(template, %{unsubscribe_url: "mailto:stop@simplefit.example"})
      end
    end

    test "every template has the layout, its footer and preheader, and is deterministic" do
      for %{template: template} <- Inventory.implemented() do
        r = rendered!(template)
        footer = Map.fetch!(@footers, Map.fetch!(@footer_of, template))

        assert r.html =~ ~r/\A<!DOCTYPE html>\n<html lang="en">/
        assert r.html =~ "SimpleFit</td>"
        assert r.html =~ Plug.HTML.html_escape(footer)
        assert r.html =~ "SimpleFit Boxing · Warsaw, Poland"
        assert r.html =~ ~s(<div style="display: none;) <> " max-height: 0;"
        assert r.html =~ r.preheader |> Plug.HTML.html_escape()
        assert r.text =~ footer
        assert r == rendered!(template)
      end
    end

    test "singular expiry wording" do
      {:ok, r} = render(:verify_email, %{expires_in_minutes: 1})
      assert r.html =~ "Expires in 1 minute<"
    end
  end

  describe "optional blocks (Version 63)" do
    test "E02 preheader and blocks follow the class and camp that are present" do
      full = rendered!(:welcome_fighter)
      no_camp = variant!(:welcome_fighter, "no-camp")
      no_class = variant!(:welcome_fighter, "no-class")
      minimal = variant!(:welcome_fighter, "minimal")

      assert no_camp.preheader == "Your class and the round timer are set."
      assert no_class.preheader == "Your camp and the round timer are set."
      assert minimal.preheader == "The round timer is set."

      refute no_camp.text =~ "fight camp"

      assert no_camp.text =~
               "You’re in, Yauheni.\n" <>
                 String.duplicate("=", 19) <> "\n\nHere’s where to start."

      refute no_class.text =~ "FIRST CLASS"
      refute no_class.html =~ "background-color: #E4EAB8;"
      assert no_class.text =~ "Your 10-week fight camp ends Tue, Nov 3. Here’s where to start."
      assert minimal.text =~ "1. Book your next class\n2. Try the round timer"
      assert full.text =~ "1. Book your next class\n   Tue"

      assert {:error, {:invalid_template_data, [camp_ends_on: :required]}} =
               without(:welcome_fighter, [:camp_ends_on])

      assert {:error, {:invalid_template_data, [first_class_room: :required]}} =
               without(:welcome_fighter, [:first_class_room])
    end

    test "E03 numbers only the pending actions and shows payouts only with the identity check" do
      identity = variant!(:welcome_coach, "identity-only")
      licence = variant!(:welcome_coach, "licence-only")
      none = variant!(:welcome_coach, "nothing-pending")

      assert identity.preheader == "Invite fighters and finish payouts."
      assert identity.text =~ "1. Finish the identity check"
      refute identity.text =~ "licence review"
      assert identity.html =~ ">Finish payouts</a>"

      assert licence.preheader == "Invite fighters and get your verified badge."
      assert licence.text =~ "1. Wait for licence review"
      refute licence.html <> licence.text =~ "Finish payouts"

      assert none.preheader == "Invite fighters with your link."
      refute none.text =~ "what’s left"
      refute none.text =~ "1. "
      refute none.html =~ "<a href"
      assert none.text =~ "Fighters can now book you and join your team.\n\nYOUR INVITE LINK"

      assert {:error, {:invalid_template_data, [payouts_url: :required]}} =
               without(:welcome_coach, [:payouts_url])

      assert {:error, {:invalid_template_data, [payouts_url: :unexpected]}} =
               render(:welcome_coach, %{identity_check_pending: false})

      assert {:error, {:invalid_template_data, errors}} =
               without(:welcome_coach, [:identity_check_pending])

      assert {:identity_check_pending, :required} in errors
    end

    test "E08 omits the tagline and the personal note when absent" do
      r = variant!(:coach_invite, "no-note-no-tagline")
      refute r.text =~ "Technique"
      refute r.text =~ "“"
      assert r.text =~ "COACH\nYauheni Coaching\n\nHi Oleg"

      assert r.text =~
               "Hi Oleg, train with me on SimpleFit.\n" <>
                 String.duplicate("=", 36) <> "\n\nWHAT YOUR COACH"
    end

    test "E12 omits the challenge and the rival line, in the body and the preheader" do
      no_rival = variant!(:first_week_recap, "no-rival")
      none = variant!(:first_week_recap, "no-challenge")

      assert no_rival.preheader == "Your Board has its first nodes."
      assert no_rival.text =~ "Gym challenge: you’re #2 of 48 in “100 rounds in October”.\n"
      refute no_rival.text =~ "Mike"

      assert none.preheader == "Your Board has its first nodes."
      refute none.text =~ "Gym challenge"

      assert {:error, {:invalid_template_data, errors}} =
               without(:first_week_recap, [
                 :challenge_name,
                 :challenge_rank,
                 :challenge_participants
               ])

      assert {:rival_name, :unexpected} in errors
    end

    test "dividers separate visible rows only, with none under the last row" do
      for {template, state, rows, absent} <- [
            {:gym_live, nil, 4, nil},
            {:gym_live, "no-verification", 3, "Verification"},
            {:gym_live, "minimal", 2, "Member invites"},
            {:member_invite, "no-home-location", 2, "Home location"},
            {:member_invite, "minimal", 1, "Active until"},
            {:join_approved, "no-booking", 2, "Booked"},
            {:join_approved, "minimal", 1, "Next billing"},
            {:account_suspended, "no-previous-notices", 3, "Previous notices"},
            {:account_suspended, "minimal", 2, "Content removed"},
            {:account_deleted, "no-retained-payments", 2, "Kept"},
            {:new_sign_in, nil, 1, nil},
            {:data_export_ready, nil, 5, nil}
          ] do
        r = if state, do: variant!(template, state), else: rendered!(template)
        assert dividers(r.html) == 2 * (rows - 1), "#{template} #{state}"
        if absent, do: refute(r.html <> r.text =~ absent, "#{template} #{state}")
      end
    end

    test "E14 omits the whole retained-records section without retained payments" do
      r = variant!(:deletion_scheduled, "no-retained-payments")
      refute r.html <> r.text =~ "WE KEEP"
      refute r.text =~ "accounting law"

      assert r.text =~
               "ON NOV 3 WE DELETE\n- Profile, trainings, Board, achievements\n- Friends, comments, videos and notes about you\n\nWant a copy first?"

      {:ok, explicit} = render(:deletion_scheduled, %{retained_gym_payments: false})
      assert explicit == r
    end

    test "no state leaves placeholders, nil, empty labels or empty panels" do
      for {template, state, r} <- all_states() do
        where = "#{template} #{state}"
        # (The HTML's media query legitimately ends in "}}".)
        refute r.html =~ ~r/\{\{|\bnil\b|\bundefined\b/, where
        refute r.text =~ ~r/\{\{|\}\}|\bnil\b|\bundefined\b/, where
        refute r.text =~ ~r/: \n|:\z|\n\n\n/, where
        refute r.html =~ ~r/<td[^>]*border-radius: 16px; padding: 18px 20px 8px;"><\/td>/, where
        refute r.html =~ ~r/<p[^>]*><\/p>/, where
        refute r.html =~ ~r/<div style="margin: 0 0 1[08]px;"><\/div>/, where
        assert r.html =~ Plug.HTML.html_escape(r.preheader), where
      end
    end
  end

  describe "HTML safety" do
    test "no scripts, event handlers, runtime CSS, placeholders or development hosts" do
      for {_template, _state, %{html: html, text: text}} <- all_states() do
        refute html =~
                 ~r/<script|javascript:|\son[a-z]+=|tailwind|<link|@import|\{\{|\bundefined\b|\bnil\b/i

        refute text =~ ~r/\{\{|\}\}|\bundefined\b|\bnil\b/
        refute html <> text =~ ~r/localhost|127\.0\.0\.1|\.dc\.html/
        assert html =~ ~s(role="presentation")
        # Narrow clients (e.g. 375 px phones): the card goes full width.
        assert html =~ "@media only screen and (max-width: 620px)"
        assert html =~ ".sf-card { width: 100% !important; }"
        assert html =~ ~s(class="sf-card" width="600")
      end
    end

    test "dynamic text is escaped, never markup" do
      hostile = ~S|<script>alert(1)</script>"><img src=x onerror=alert(2)>|
      {:ok, r} = render(:account_deleted, %{name: hostile})

      refute r.html =~ "<script>"
      refute r.html =~ "<img"

      assert r.html =~
               "&lt;script&gt;alert(1)&lt;/script&gt;&quot;&gt;&lt;img src=x onerror=alert(2)&gt;"
    end

    test "every display variable of every template is escaped" do
      hostile = ~S|<b>&"x|

      for %{template: template} <- Inventory.implemented(),
          {field, value} <- Fixtures.for_template(template),
          field not in @strict_fields,
          not String.ends_with?(Atom.to_string(field), "_url"),
          is_binary(value) or is_list(value) do
        override = if is_list(value), do: [hostile], else: hostile
        assert {:ok, r} = render(template, %{field => override}), "#{template}.#{field}"
        refute r.html =~ "<b>&", "#{template}.#{field} reached the HTML unescaped"
        # Eyebrows upper-case their value.
        assert r.html =~ ~r/&lt;b&gt;&amp;&quot;x/i
      end
    end

    test "URL query strings are attribute-escaped" do
      url = "https://app.simplefit.example/settings?a=1&b='2'"
      {:ok, r} = render(:deletion_scheduled, %{restore_url: url})
      assert r.html =~ "href=\"https://app.simplefit.example/settings?a=1&amp;b=&#39;2&#39;\""
    end

    test "the plain text has no HTML artifacts" do
      for {_template, _state, %{text: text}} <- all_states() do
        refute text =~ ~r/<[a-z\/!]|&(amp|lt|gt|quot|#\d+);/
      end
    end
  end

  describe "validation" do
    test "a missing required variable is rejected" do
      for %{template: template, required_variables: required} <- Inventory.implemented(),
          variable <- required do
        attrs = Map.delete(Fixtures.for_template(template), String.to_existing_atom(variable))
        field = String.to_existing_atom(variable)

        assert {:error, {:invalid_template_data, errors}} = apply(Templates, template, [attrs])
        assert {field, :required} in errors
      end
    end

    test "nil and blank values never render" do
      assert {:error, {:invalid_template_data, [{:name, :required}]}} =
               render(:account_deleted, %{name: nil})

      assert {:error, {:invalid_template_data, [{:name, :required}]}} =
               render(:account_deleted, %{name: "   "})
    end

    test "malformed variables are rejected" do
      assert {:error, {:invalid_template_data, [code: :invalid_format]}} =
               render(:verify_email, %{code: "40719"})

      assert {:error, {:invalid_template_data, [expires_in_minutes: :out_of_range]}} =
               render(:verify_email, %{expires_in_minutes: 0})

      assert {:error, {:invalid_template_data, [expires_in_minutes: :invalid_type]}} =
               render(:verify_email, %{expires_in_minutes: "soon"})

      assert {:error, {:invalid_template_data, [requested_on: :invalid_type]}} =
               render(:account_deleted, %{requested_on: "yesterday"})

      assert {:error, {:invalid_template_data, [deletion_on: :out_of_range]}} =
               render(:deletion_scheduled, %{deletion_on: ~D[2026-10-01]})

      assert {:error, {:invalid_template_data, [name: :too_long]}} =
               render(:account_deleted, %{name: String.duplicate("a", 81)})
    end

    test "unsafe CTA URLs are rejected" do
      for url <- [
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "http://app.simplefit.example/verify",
            "ftp://app.simplefit.example/verify",
            "/relative/path",
            "https://",
            "https://user:pass@app.simplefit.example/verify",
            "https://app.simplefit.example/ver ify",
            "https://app.simplefit.example/verify\r\nX-Injected: 1",
            "https://app.simplefit.example/" <> String.duplicate("a", 2048)
          ] do
        assert {:error, {:invalid_template_data, [verify_url: :invalid_url]}} =
                 render(:verify_email, %{verify_url: url}),
               "expected #{inspect(url)} to be rejected"
      end
    end

    test "every CTA and link URL of every template is validated" do
      for %{template: template} <- Inventory.implemented(),
          field <- Map.keys(Fixtures.for_template(template)),
          String.ends_with?(Atom.to_string(field), "_url"),
          url <- ["javascript:alert(1)", "http://app.simplefit.example/x", "/x", "https://"] do
        assert {:error, {:invalid_template_data, [{^field, :invalid_url}]}} =
                 render(template, %{field => url}),
               "#{template}.#{field} accepted #{inspect(url)}"
      end
    end

    test "list variables reject empty, oversized and control-character items" do
      for {template, field, max} <- [
            {:gym_live, :locations, 20},
            {:staff_invite, :permissions, 8},
            {:first_week_recap, :board_items, 6}
          ],
          value <- [[], List.duplicate("a", max + 1), ["ok", "bad\nline"], [" "], "not a list"] do
        assert {:error, {:invalid_template_data, [{^field, _reason}]}} =
                 render(template, %{field => value}),
               "#{template}.#{field} accepted #{inspect(value)}"
      end
    end

    test "http is accepted only where development explicitly allows it" do
      with_template_config(allow_http_urls: true)
      assert {:ok, _} = render(:verify_email, %{verify_url: "http://localhost:3000/verify?t=1"})
    end

    test "CR/LF and control characters cannot reach the subject or text lines" do
      for value <- ["Karol\r\nBcc: a@b.c", "Karol\nX", "Karol\u0000", "Karol\u2028X"] do
        assert {:error, {:invalid_template_data, [name: :invalid_format]}} =
                 render(:account_deleted, %{name: value})
      end

      for %{template: template} <- Inventory.implemented() do
        refute rendered!(template).subject =~ ~r/[\r\n]/
      end
    end

    test "errors name fields only, never the rejected value" do
      secret = "https://user:SECRET-TOKEN@app.simplefit.example/verify"
      assert {:error, error} = render(:verify_email, %{verify_url: secret})
      refute inspect(error) =~ "SECRET-TOKEN"
    end
  end

  describe "delivery integration" do
    test "a rendered template becomes one message with HTML and plain text" do
      r = rendered!(:verify_email)
      assert {:ok, %Message{} = message} = Templates.to_message(r, to: "fighter@example.com")

      assert message.subject == r.subject
      assert message.html == r.html
      assert message.text == r.text
      assert message.to == ["fighter@example.com"]
    end

    test "invalid recipients are rejected before delivery" do
      r = rendered!(:verify_email)
      assert Templates.to_message(r, to: "nope\r\nBcc: x@y.z") == {:error, :invalid_request}
    end

    test "goes through deliver_later, the mailers queue and the configured adapter" do
      {:ok, message} =
        Templates.to_message(rendered!(:recover_account), to: "fighter@example.com")

      {:ok, %Oban.Job{id: id}} = Email.deliver_later(message)

      assert %{success: 1} = Oban.drain_queue(queue: :mailers)
      key = "email-job-#{id}"
      assert_received {:email_delivered, ^message, [idempotency_key: ^key]}
    end
  end

  describe "privacy" do
    test "the job stores no code, URL, recipient or subject" do
      r = rendered!(:verify_email)
      {:ok, message} = Templates.to_message(r, to: "fighter@example.com")
      {:ok, job} = Email.deliver_later(message)
      stored = inspect(Repo.get!(Oban.Job, job.id), limit: :infinity)

      for secret <- [
            "407193",
            "407 193",
            "FIXTURE-ONE-TIME-TOKEN",
            "fighter@example.com",
            "Confirm"
          ] do
        refute stored =~ secret
      end

      assert {:ok, ^message} = JobPayload.open(job.args["payload"])
    end

    test "inspect hides rendered content and message bodies" do
      r = rendered!(:verify_email)
      {:ok, message} = Templates.to_message(r, to: "fighter@example.com")

      for value <- [r, message], secret <- ["407193", "FIXTURE-ONE-TIME-TOKEN"] do
        refute inspect(value) =~ secret
      end
    end

    test "the development log adapter never logs subject or body" do
      {:ok, message} = Templates.to_message(rendered!(:verify_email), to: "fighter@example.com")

      log =
        capture_log([level: :info], fn ->
          Logger.configure(level: :info)
          assert {:ok, _} = Email.Log.deliver(message, [], [])
          Logger.configure(level: :warning)
        end)

      assert log =~ "email not sent"
      refute log =~ "407193"
      refute log =~ "FIXTURE-ONE-TIME-TOKEN"
      refute log =~ "fighter@example.com"
    end

    test "delivery logs and telemetry never carry content", %{} do
      {:ok, message} = Templates.to_message(rendered!(:verify_email), to: "fighter@example.com")

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:simple_fit, :email, :deliver, :stop]])

      log = capture_log(fn -> Email.deliver(message) end)

      assert_received {[:simple_fit, :email, :deliver, :stop], ^ref, _measurements, metadata}
      refute inspect(metadata) =~ "407193"
      refute log =~ "407193"
    end

    test "permanent and transient failures keep their semantics with templated mail" do
      {:ok, message} = Templates.to_message(rendered!(:verify_email), to: "fighter@example.com")
      {:ok, payload} = JobPayload.seal(message)

      Process.put(:email_error, :timeout)
      assert {:error, :timeout} = perform_job(DeliveryWorker, %{"payload" => payload})

      Process.put(:email_error, :invalid_request)
      assert {:cancel, :invalid_request} = perform_job(DeliveryWorker, %{"payload" => payload})
    end
  end
end
