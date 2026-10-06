# ADR 0011 — Transactional email templates

* Status: Accepted
* Date: 2026-10-06
* Ticket: SF-35 (on the SF-15 email boundary, ADR 0005/0006)

## Context

Claude Design defines 17 emails (E01–E17) on the Public Website page,
section "14 · Email templates · after registration" (artifact
https://claude.ai/artifact/JEsBg51MjX8KiHWEro8omY, Version 66,
`1791292422-dc85`; artboards `project/Email*.dc.html`). E01–E16 were
reconciled to Version 63 in SF-35; SF-21 updated E01 and added E17 from
Version 66 (ADR 0012). Verification, recovery and account-lifecycle flows will
send some of them soon (SF-21, SF-28); most belong to domains that do not
exist yet (gyms, coaching, moderation, data export). SF-15 built delivery
only: `SimpleFit.Email`, Resend, Oban.

## Decision

### The application owns the templates

```
domain flow (SF-21, SF-28, …)
   ↓ validated variables
SimpleFit.Email.Templates.<template>/1   → Rendered: subject, preheader, HTML, text
   ↓ Templates.to_message/2
SimpleFit.Email.Message → deliver_later/1 → Oban mailers queue → Resend | Log adapter
```

* Templates live in `lib/simple_fit/email/templates/`, one module per
  designed email, behind explicit functions (`Templates.verify_email/1`,
  …). There is no generic or user-supplied template execution and no
  Resend-hosted template: changing provider changes nothing here.
* `SimpleFit.Email.Templates.Layout` renders the shared frame and body
  blocks twice: email-safe HTML and a written plain-text part with the same
  message, CTA URLs and security copy.
* Rendering is deterministic: no random ids or clocks. The sending domain
  owns triggers and idempotency.

### Presentation data, not domain data

A template is implemented whenever its content can be determined from the
artboard, even if its domain does not exist yet. Its renderer accepts
explicit, validated presentation data and reads nothing: no `Repo`, no Ecto
schema, no context call (a test enforces this). Implementing a template
does not implement its API, domain model, tables, trigger, tokens,
booking/payment/membership behaviour, moderation workflow or
unsubscribe/preferences workflow.

* Values that describe a specific record (names, dates, counts, plan and
  billing lines, file details, permission lists) are variables. Copy that
  describes SimpleFit behaviour or policy stays the design's fixed copy.
* A record line the sending domain must phrase (e.g. "175 · tomorrow
  10:00", "Nov 1 · €79 · Visa •• 4242") is a validated one-line display
  string; full card numbers or other secrets never belong in one.
* Opt-out (E07), Email preferences and Unsubscribe (E02, E12) links are
  validated URLs supplied by the sender. No preference, unsubscribe or
  opt-out system exists, and no `List-Unsubscribe` header is sent.
* User-written text (E08's coach note) is plain text: one paragraph, at
  most 500 characters, escaped like every other value.
* Displayed lifetimes (E11's link expiry, E16's availability and expiry)
  are presentation data; the owning domains set the real policies.

### Optional blocks and variants

Version 63 marks optional blocks and preheader variants. They are
presentation intent; the renderers translate them into their own input
contracts rather than copying the design's condition names.

* Variables are required unless listed as optional. An optional variable
  is absent when missing or `nil`; when present it is validated like any
  other (a blank value is rejected, never shown as an empty label).
* Values that only make sense together are one group, all or none (E02's
  camp and first class, E04's progress, E12's challenge and rival).
* A value supplied where the email would not show it is `:unexpected`
  (E03's payouts URL without a pending identity check, E12's rival without
  a challenge), so callers never invent data.
* An absent block disappears entirely: no spacing, label, panel or
  divider is left. Label/value tables draw a divider between visible rows
  only; the markup is generated that way, never repaired by CSS selectors
  or scripts.
* Preheaders follow the present data: E02 (class/camp, four variants),
  E03 (identity check/licence review, four), E12 (rival, two).
* E03 numbers only the pending actions; with none there is no lead-in, no
  list and no primary button.
* Booleans state facts the email shows as fixed copy: E03's pending
  actions, E14/E15's `retained_gym_payments` (default `false`).

### Variables and URLs

* Each template declares its variables (Ecto types) and validates them
  before rendering. A missing, blank, `nil`, malformed or out-of-range value
  returns `{:error, {:invalid_template_data, [{field, reason}]}}`; nothing is
  rendered or enqueued.
* Errors name fields and reasons only, never values, so a rejected code or
  URL cannot leak.
* CTA URLs are supplied by the sending domain, which owns credentials (for
  example SF-21's verification token).
* URLs must be absolute `https` with a host and no user info, whitespace or
  control characters; `javascript:`, `data:` and every other scheme are
  rejected. `http` is accepted only where `config/dev.exs` sets
  `allow_http_urls: true` (the local web app).
* No production URL is hard-coded and no new environment variable is
  needed.

### Escaping and headers

* Every dynamic value is HTML-escaped by the layout (`Plug.HTML`); templates
  never build markup. There is no "safe HTML" escape hatch.
* Display text must be a single line without control characters, so
  CR/LF can reach neither a subject nor a header.
* `SimpleFit.Email.Message` keeps its SF-15 header-injection checks.

### Email-safe HTML

* Built from table layout, inline styles, explicit 600 px width, `role="presentation"`
  and a hidden preheader, plus one `<style>` media query for narrow screens.
* No scripts, no external CSS, no web fonts loaded, no images.
* Font stacks name the design fonts first (Unbounded, Manrope, JetBrains
  Mono) and fall back to system fonts, because web fonts are unreliable in
  email clients.

### Job payload privacy

Oban stores job arguments in PostgreSQL until they are pruned, and backups
copy them. Verification and recovery emails carry one-time codes and
credential-bearing URLs. `deliver_later/1` therefore stores only
ciphertext:

* `SimpleFit.Email.JobPayload` encrypts the message with
  `Plug.Crypto.encrypt/4`: XChaCha20-Poly1305 authenticated encryption
  (plug_crypto 2.x), a random 192-bit nonce per payload, and a 256-bit key
  derived from `SECRET_KEY_BASE` by PBKDF2-HMAC-SHA256 with the dedicated
  salt `"simplefit email job payload v1"` (sessions use their own salt).
  The seal time is inside the authenticated ciphertext; the reader enforces
  the lifetime. `payload_key_base` is configured per environment;
  production uses `SECRET_KEY_BASE`.
* Sealed payloads are valid for 7 days. A payload that cannot be decrypted
  (tampering, or a `SECRET_KEY_BASE` rotation) cancels its job.
* `Message` and `Rendered` hide subjects and bodies from `inspect/2`.
* The development `Email.Log` adapter logs recipient count and part sizes,
  never the subject: E01's subject contains the code.

Delivery semantics are unchanged: the per-job idempotency key, retries of
transient failures and cancellation of permanent ones.

### Development preview

`GET /dev/emails` lists all 16 designed emails; `GET /dev/emails/:id`
renders one with deterministic fixtures (reserved `.example` domain, fake
one-time token), as HTML or `?format=text`. Default fixtures show every
optional block; `?variant=<name>` renders a named optional state
(`Fixtures.variants/1`, e.g. E04 `no-progress`, E03 `nothing-pending`).

* Enabled only by `config/dev.exs`; elsewhere the routes answer like unknown
  routes, so they can never be switched on in production.
* The preview has its own CSP and is not in the OpenAPI contract.
* Nothing is sent.

### Inventory and status

`SimpleFit.Email.Templates.Inventory` is the traceability record: every
designed email with its trigger, subject, preheader or preheader variants,
required and optional variables, conditional blocks, CTA, fallback,
design artboard, delivery owner, status and deferred product questions.
Undefined values are `NOT_SPECIFIED`.

All 17 are implemented. SF-21 wires the triggers of E01 and E17
(passwordless email authentication, ADR 0012); every other trigger is
deferred.

| Id | Email | Status | Trigger owner |
| --- | --- | --- | --- |
| E01 | Verify your email | IMPLEMENTED_TEMPLATE / TRIGGER_AVAILABLE | SF-21 |
| E02 | Welcome, fighter | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future fighter onboarding |
| E03 | Welcome, coach | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future coach onboarding |
| E04 | Finish gym setup | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future gym onboarding |
| E05 | Your gym is live | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future gym publishing |
| E06 | Staff invitation | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future gym staff |
| E07 | Member invite from gym | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future membership import |
| E08 | Coach invited you | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future coaching |
| E09 | Join request approved | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future membership |
| E10 | New sign-in alert | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | SF-28 / security (expected) |
| E11 | Recover account | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | SF-28 (expected) |
| E12 | First week recap | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future training recap |
| E13 | Account suspended | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future moderation |
| E14 | Deletion scheduled | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | SF-28 (expected) |
| E15 | Account deleted | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | SF-28 (expected) |
| E16 | Data export ready | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | future data export |
| E17 | Sign-in code | IMPLEMENTED_TEMPLATE / TRIGGER_AVAILABLE | SF-21 |

Apart from E01 and E17, no backend flow sends these emails yet: the owning
tickets build the events, credentials, links and workflows.

Version 66 changes reconciled in SF-21 (ADR 0012):

* **E01** is email ownership verification only: "Verify your email", the
  code and a "Verify email" link that answer the same challenge, and the
  explicit "Opening the link doesn't sign you in". `verify_url` is
  `<WEB_APP_URL>/verify-email#token=...` (token in the fragment, never the
  code). The contract (`code`, `verify_url`, `expires_in_minutes`) is
  unchanged; the expiry comes from the challenge policy.
* **E17** (new) is the sign-in code: code, expiry, "Never share this code",
  no link.

Version 63 changes reconciled in SF-35:

* **E04** is navigation only: "Continue setup" opens the setup and the
  person signs in as usual if needed. No sign-in link, token or resume
  state; setup progress is optional.
* **E08** has no pronoun input; the preheader names the coach. Tagline
  and personal note are optional.
* **E10** states only the sign-in time. It claims no device, browser,
  location or method, and promises no sign-out or restriction.
* **E11** is a recovery link only: no code, no passkey wording.
* **E14** no longer claims a hidden profile, signed-out devices or a
  one-tap restore; the retained-payments section is optional (E15's row
  too).
* **E16** does not say how the download authenticates.

### Deferred product questions

These do not block rendering; their owners decide them.

* **Security destination (E10, E11, E16):** the account security settings
  screen still shows future security concepts (passkeys, authenticator,
  global sign-out). SF-35 does not change it; SF-28 / security
  reconciliation owns it. Nothing detects a new sign-in yet (E10).
* **E05:** "codes rotate so they can’t be shared" needs confirmation by
  the future gym/check-in domain; SF-35 implements no QR rotation.
* **E09:** the copy describes a front-desk confirmation; online join flows
  may need their own copy or variant.
* **E02:** "weight and RPE never leave your phone" may conflict with the
  coach-visible metrics a fighter shares with consent (E08); the
  fighter/coach domain reconciles it.
* **E07:** the privacy note says the gym shared name, email and plan; the
  membership/import domain confirms what an import really shares.
* **E01:** resolved by SF-21: the code and the link both answer the same
  verification challenge (ADR 0012).
* **E11/E16 lifetimes:** displayed values are presentation data; SF-28
  and the export domain own the real credential and storage expiry.
* **E02/E12:** Email preferences and Unsubscribe destinations do not exist
  yet.

### Deliberate deviations from the artboards

* **No logo or icon glyphs:** the design's "Corner S" mark, E06's gym avatar
  and E12's Board icon are inline SVG, which major email clients do not
  render, and there are no hosted raster images. The header shows the
  "SimpleFit" wordmark only; E06 shows the gym name without the avatar.
* **No footer Help · Privacy · Terms links:** the design links them to `#`,
  and no production Help, Privacy or Terms page exists in the route
  registry.
* **Sender:** the design shows category senders (`SimpleFit Security
  <security@…>`), but production keeps the single configured `EMAIL_FROM`.
* **Fonts:** fallback stacks instead of loaded web fonts.
* **Client rendering:** rounded corners and shadows degrade in clients that
  ignore them (Outlook desktop), and the card has no drop shadow.
* **E04 progress bar:** table cells with background colours; their rounded
  ends degrade to square in clients that ignore `border-radius`.
* **Language:** English only. The design marks "EN · also PL · UK · CS",
  but only English copy is designed; other languages are future work.

### Adding a template

1. Re-read the artboard from the canvas and record the version.
2. Add a module under `templates/`, a `Templates` function, fixture data
   and the inventory entry (status, owner).
3. Add rendering, validation and safety tests.
4. Check it in `/dev/emails` against the artboard.
5. The owning domain ticket wires the trigger.

## Consequences

* Future flows only pass validated data and a URL; markup, escaping,
  plain text and delivery are shared.
* Rotating `SECRET_KEY_BASE` cancels emails still queued at that moment
  (minutes in practice).
* All 17 templates are ready for their domains; their triggers, tokens,
  links and workflows belong to the tickets that build those domains.
* A design change re-reads the artboards, updates the renderer, inventory
  and fixtures, and records the new version.
