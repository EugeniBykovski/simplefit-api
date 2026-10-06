# ADR 0011 — Transactional email templates

* Status: Accepted
* Date: 2026-10-06
* Ticket: SF-35 (on the SF-15 email boundary, ADR 0005/0006)

## Context

Claude Design defines 16 emails (E01–E16) on the Public Website page,
section "14 · Email templates · after registration" (artifact
https://claude.ai/artifact/JEsBg51MjX8KiHWEro8omY, version
`1791276973-ad1d`). Verification, recovery and account-lifecycle flows will
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
* User-written text (E08's coach message) is plain text: one paragraph,
  at most 500 characters, escaped like every other value.
* E08's preheader ("Join his team…") takes `coach_possessive` (`his`, `her`
  or `their`) from the sender; it is never inferred from a name.

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

`GET /dev/emails` lists every designed email; `GET /dev/emails/:id` renders
an implemented one with deterministic fixtures (reserved `.example`
domain, fake one-time token), as HTML or `?format=text`.

* Enabled only by `config/dev.exs`; elsewhere the routes answer like unknown
  routes, so they can never be switched on in production.
* The preview has its own CSP and is not in the OpenAPI contract.
* Nothing is sent.

### Inventory and status

`SimpleFit.Email.Templates.Inventory` is the traceability record: every
designed email with its trigger, subject, preheader, variables, CTA,
fallback, artboard, delivery owner and status. Undefined values are
`NOT_SPECIFIED`.

| Id | Email | Status | Trigger owner |
| --- | --- | --- | --- |
| E01 | Verify your email | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | SF-21 |
| E02 | Welcome, fighter | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E03 | Welcome, coach | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E04 | Finish gym setup | AMBIGUOUS / NEEDS_PRODUCT_DECISION | — |
| E05 | Your gym is live | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E06 | Staff invitation | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E07 | Member invite from gym | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E08 | Coach invited you | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E09 | Join request approved | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E10 | New sign-in alert | AMBIGUOUS / NEEDS_PRODUCT_DECISION | — |
| E11 | Recover account | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | SF-28 (expected) |
| E12 | First week recap | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E13 | Account suspended | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |
| E14 | Deletion scheduled | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | SF-28 (expected) |
| E15 | Account deleted | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | SF-28 (expected) |
| E16 | Data export ready | IMPLEMENTED_TEMPLATE / TRIGGER_DEFERRED | no ticket yet (domain missing) |

No trigger is wired in SF-35: no backend flow sends any of these emails
yet.

E04 and E10 are not implemented because their approved copy promises
behaviour that does not exist, and SF-35 does not rewrite approved copy:

* **E04:** "This link signs you in and is valid for 24 hours" is a
  sign-in-by-email-link credential outside the session model (ADR 0010);
  "Book a free 15-minute setup call with Gym Success" has no destination.
* **E10:** sessions store no device or location and nothing detects a new
  device; "Password + authenticator" is not a SimpleFit sign-in method;
  "posting and messaging from this device are paused for 24 hours" and "we’ll
  sign out every other device and ask you to confirm with your passkey"
  describe features that do not exist.

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
* Fourteen templates are ready for their domains; their triggers, tokens
  and links belong to the tickets that build those domains.
* E04 and E10 wait for revised copy or the features their copy promises.
