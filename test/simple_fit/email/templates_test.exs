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
    :primary_cta,
    :fallback_url,
    :artboard,
    :delivery_owner,
    :status
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
    gym_live: :activity,
    staff_invite: :invitation,
    member_invite: :invitation,
    coach_invite: :invitation,
    join_approved: :activity,
    recover_account: :security,
    first_week_recap: :member,
    account_suspended: :security,
    deletion_scheduled: :security,
    account_deleted: :security,
    data_export_ready: :security
  }

  # Fields whose format is stricter than a display line (codes, enums).
  @strict_fields [:code, :case_id, :coach_initials, :coach_possessive, :payout_day]

  defp render(template, overrides \\ %{}) do
    apply(Templates, template, [Map.merge(Fixtures.for_template(template), overrides)])
  end

  defp rendered!(template) do
    {:ok, %Rendered{} = rendered} = render(template)
    rendered
  end

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
    test "covers every designed email E01..E16 exactly once, in design order" do
      ids = Enum.map(Inventory.entries(), & &1.id)
      assert ids == Enum.map(1..16, &("E" <> String.pad_leading(Integer.to_string(&1), 2, "0")))
    end

    test "records the design source and version" do
      assert %{
               artifact: "https://claude.ai/artifact/JEsBg51MjX8KiHWEro8omY",
               version: "1791276973-ad1d",
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
        assert entry.artboard =~ ~r/\AEmail[A-Za-z0-9]+\.dc\.html\z/
      end
    end

    test "every implemented template maps to its artboard, module and trigger owner" do
      implemented = Inventory.implemented()

      assert Enum.map(implemented, & &1.id) ==
               ~w(E01 E02 E03 E05 E06 E07 E08 E09 E11 E12 E13 E14 E15 E16)

      assert Map.keys(@footer_of) |> Enum.sort() ==
               implemented |> Enum.map(& &1.template) |> Enum.sort()

      for entry <- implemented do
        assert entry.status == "IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED"
        assert Code.ensure_loaded?(entry.module)
        assert function_exported?(Templates, entry.template, 1)
        assert is_list(entry.required_variables)
        assert is_binary(entry.trigger_owner)

        # The declared variables are exactly what the fixture needs.
        assert entry.required_variables |> Enum.sort() ==
                 Fixtures.for_template(entry.template)
                 |> Map.keys()
                 |> Enum.map(&Atom.to_string/1)
                 |> Enum.sort()
      end
    end

    test "templates not implemented carry a reason and no production module" do
      for entry <- Inventory.entries(), not Map.has_key?(entry, :template) do
        assert entry.status in [
                 "DESIGN_ONLY / DOMAIN_NOT_AVAILABLE",
                 "AMBIGUOUS / NEEDS_PRODUCT_DECISION"
               ]

        assert is_binary(entry.note)
      end
    end

    test "E04 and E10 stay ambiguous: their approved copy promises behaviour that does not exist" do
      e04 = Enum.find(Inventory.entries(), &(&1.id == "E04"))
      e10 = Enum.find(Inventory.entries(), &(&1.id == "E10"))

      for entry <- [e04, e10] do
        assert entry.status == "AMBIGUOUS / NEEDS_PRODUCT_DECISION"
        refute Map.has_key?(entry, :template)
      end

      assert e04.note =~ "This link signs you in and is valid for 24 hours"
      assert e10.note =~ "Password + authenticator"
      assert e10.note =~ "24-hour posting/messaging pause"
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
      assert adr =~ "1791276973-ad1d"
    end
  end

  describe "rendering" do
    test "E01 verify email" do
      r = rendered!(:verify_email)

      assert r.subject == "Your SimpleFit code: 407193"
      assert r.preheader == "Enter it in the app to confirm your email."
      assert r.html =~ "Confirm your email</h1>"
      assert r.html =~ "407 193"
      assert r.html =~ "Expires in 10 minutes"

      assert r.html =~
               ~s(href="https://app.simplefit.example/signup/verify?token=FIXTURE-ONE-TIME-TOKEN")

      assert r.html =~ ">Verify email</a>"

      assert r.text =~
               "Verify email:\nhttps://app.simplefit.example/signup/verify?token=FIXTURE-ONE-TIME-TOKEN"

      assert r.text =~ "no account is created without the code"
    end

    test "E11 recover account" do
      r = rendered!(:recover_account)

      assert r.subject == "Recover your SimpleFit account"
      assert r.preheader == "Use this link within 15 minutes."
      assert r.html =~ "Recover your account</h1>"
      assert r.html =~ ">Sign in and add a new passkey</a>"
      assert r.html =~ "K7Q-2MX"
      assert r.html =~ "Valid for 15 minutes · works once"
      assert r.text =~ "https://app.simplefit.example/recover?token=FIXTURE-ONE-TIME-TOKEN"
      assert r.text =~ "your account stays locked without the code"
    end

    test "E14 deletion scheduled" do
      r = rendered!(:deletion_scheduled)

      assert r.subject == "Your account will be deleted on Nov 3"
      assert r.preheader == "Changed your mind? Restore it with one tap before then."
      assert r.html =~ "Your account will be deleted on Nov 3.</h1>"
      assert r.html =~ "We received your request on Oct 4."
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
    end

    test "E03 welcome coach" do
      r = rendered!(:welcome_coach)

      assert r.subject == "Your coaching space is ready"
      assert r.html =~ "YAUHENI COACHING"
      assert r.html =~ ">sfit.example/c/yauheni</p>"
      assert r.html =~ ~s(href="https://app.simplefit.example/coach/payouts")
      assert r.text =~ "2. Wait for licence review"
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
      assert r.preheader == "Join his team on SimpleFit — your log stays yours."
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

      for possessive <- ["him", "His", ""] do
        assert {:error, {:invalid_template_data, [coach_possessive: _]}} =
                 render(:coach_invite, %{coach_possessive: possessive})
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

  describe "HTML safety" do
    test "no scripts, event handlers, runtime CSS, placeholders or development hosts" do
      for %{template: template} <- Inventory.implemented() do
        %{html: html, text: text} = rendered!(template)

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
      for %{template: template} <- Inventory.implemented() do
        refute rendered!(template).text =~ ~r/<[a-z\/!]|&(amp|lt|gt|quot|#\d+);/
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

      assert {:error, {:invalid_template_data, [code: :invalid_format]}} =
               render(:recover_account, %{code: "k7q-2mx"})

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
